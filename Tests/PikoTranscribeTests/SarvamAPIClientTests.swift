import Foundation
import Testing
@testable import PikoTranscribe

#if os(iOS)

/// URLProtocol stub so we exercise the real request-construction and error paths
/// against a canned response without touching the network.
final class SarvamStubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var statusCode: Int
        var body: Data
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    nonisolated(unsafe) static var next: Stub?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips httpBody for streamed uploads — read from bodyStream too.
        Self.lastRequest = request
        if let body = request.httpBody {
            Self.lastRequestBody = body
        } else if let stream = request.httpBodyStream {
            var collected = Data()
            stream.open()
            defer { stream.close() }
            let bufSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufSize)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            Self.lastRequestBody = collected
        }
        guard let stub = Self.next else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("SarvamAPIClient", .serialized)
struct SarvamAPIClientTests {

    private func stubbedClient(apiKey: String = "sk_test_key") -> SarvamAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SarvamStubProtocol.self]
        let session = URLSession(configuration: config)
        return SarvamAPIClient(apiKey: apiKey, session: session)
    }

    @Test func emptyKeyThrowsBeforeAnyNetwork() async {
        SarvamStubProtocol.next = nil
        SarvamStubProtocol.lastRequest = nil
        let client = stubbedClient(apiKey: "")
        await #expect(throws: SarvamError.missingAPIKey) {
            try await client.transcribe(audioData: Data(repeating: 0, count: 32))
        }
        #expect(SarvamStubProtocol.lastRequest == nil, "no network hit on missing key")
    }

    @Test func emptyAudioThrowsBeforeAnyNetwork() async {
        SarvamStubProtocol.next = nil
        SarvamStubProtocol.lastRequest = nil
        let client = stubbedClient()
        await #expect(throws: SarvamError.noAudioData) {
            try await client.transcribe(audioData: Data())
        }
        #expect(SarvamStubProtocol.lastRequest == nil, "no network hit on empty audio")
    }

    @Test func successfulResponseIsDecoded() async throws {
        let payload = #"{"transcript":"hello there","language_code":"en-IN","language_probability":0.94}"#
        SarvamStubProtocol.next = .init(statusCode: 200, body: Data(payload.utf8))
        let client = stubbedClient()
        let result = try await client.transcribe(audioData: Data(repeating: 0xAB, count: 128))
        #expect(result.transcript == "hello there")
        #expect(result.languageCode == "en-IN")
        #expect(abs(result.languageProbability - 0.94) < 0.001)
    }

    @Test func requestUsesAPIKeyHeaderAndMultipartBody() async throws {
        let payload = #"{"transcript":"ok"}"#
        SarvamStubProtocol.next = .init(statusCode: 200, body: Data(payload.utf8))
        let client = stubbedClient(apiKey: "sk_header_marker")
        _ = try await client.transcribe(audioData: Data(repeating: 0x01, count: 16))
        let request = SarvamStubProtocol.lastRequest!
        #expect(request.url?.path == "/speech-to-text")
        #expect(request.value(forHTTPHeaderField: "api-subscription-key") == "sk_header_marker")
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = SarvamStubProtocol.lastRequestBody ?? Data()
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        // Multipart form fields we always send.
        #expect(bodyString.contains("name=\"file\"; filename=\"audio.wav\""))
        #expect(bodyString.contains("name=\"model\""))
        #expect(bodyString.contains("saaras:v3"))
        #expect(bodyString.contains("name=\"language_code\""))
        #expect(bodyString.contains("name=\"mode\""))
    }

    @Test func httpErrorSurfaceCarriesStatusCode() async {
        SarvamStubProtocol.next = .init(statusCode: 500, body: Data("boom".utf8))
        let client = stubbedClient()
        do {
            _ = try await client.transcribe(audioData: Data(repeating: 0, count: 32))
            Issue.record("expected throw")
        } catch let SarvamError.httpError(code, _) {
            #expect(code == 500)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func healthCheckOk() async {
        let payload = #"{"transcript":""}"#
        SarvamStubProtocol.next = .init(statusCode: 200, body: Data(payload.utf8))
        let client = stubbedClient()
        let result = await client.healthCheck()
        #expect(result == .ok)
    }

    @Test func healthCheckUnauthorized() async {
        SarvamStubProtocol.next = .init(statusCode: 401, body: Data("nope".utf8))
        let client = stubbedClient()
        let result = await client.healthCheck()
        #expect(result == .unauthorized)
    }

    @Test func healthCheckMissingKey() async {
        SarvamStubProtocol.next = nil
        let client = stubbedClient(apiKey: "")
        let result = await client.healthCheck()
        #expect(result == .unauthorized)
    }
}

#endif
