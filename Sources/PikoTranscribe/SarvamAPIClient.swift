#if os(iOS)
import Foundation
import PikoKit

/// Thin actor around the Sarvam speech-to-text endpoint. One request per capture
/// (the recording is batched at `finish()`), multipart form-data body, API key in
/// the `api-subscription-key` header. `URLSession` is injectable so tests can plug
/// a `URLProtocol` stub without touching the network.
public actor SarvamAPIClient {
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    /// Construct with the caller's key and (optionally) a custom URLSession. An
    /// empty key still constructs — the engine layer refuses to *use* one — so
    /// that a "not configured yet" state can round-trip through composition
    /// without throwing at init.
    public init(apiKey: String,
                baseURL: URL = URL(string: "https://api.sarvam.ai")!,
                session: URLSession? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: config)
        }
    }

    public struct TranscriptionResult: Sendable, Equatable {
        public let transcript: String
        public let languageCode: String
        public let languageProbability: Double
    }

    /// Fast, cheap credential check. Sends a small WAV silence payload — enough to
    /// trigger an auth check against the endpoint without a real transcription round.
    /// Returns `.ok` on any 2xx, `.unauthorized` on 401/403, otherwise `.failed`.
    public func healthCheck() async -> HealthCheckResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unauthorized
        }
        let silence = Self.silentWAV(seconds: 0.5, sampleRate: 16_000)
        do {
            _ = try await transcribe(audioData: silence, languageCode: "unknown", mode: "transcribe")
            return .ok
        } catch SarvamError.httpError(let code, _) where code == 401 || code == 403 {
            return .unauthorized
        } catch {
            return .failed(String(describing: error))
        }
    }

    public enum HealthCheckResult: Sendable, Equatable {
        case ok
        case unauthorized
        case failed(String)
    }

    /// A minimum-length WAV of silence, used only for the credential check.
    private static func silentWAV(seconds: Double, sampleRate: Int) -> Data {
        let frameCount = Int(seconds * Double(sampleRate))
        let pcm = Data(count: frameCount * 2) // 16-bit mono
        let bitsPerSample = 16
        let channels = 1
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = pcm.count
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        header.append(pcm)
        return header
    }

    public func transcribe(
        audioData: Data,
        languageCode: String = "unknown",
        mode: String = "transcribe",
        withTimestamps: Bool = false
    ) async throws -> TranscriptionResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SarvamError.missingAPIKey
        }
        guard !audioData.isEmpty else {
            throw SarvamError.noAudioData
        }

        let url = baseURL.appendingPathComponent("speech-to-text")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        appendField("model", "saaras:v3")
        appendField("language_code", languageCode)
        appendField("mode", mode)
        appendField("with_timestamps", withTimestamps ? "true" : "false")

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SarvamError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw SarvamError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        let decoded = try JSONDecoder().decode(SarvamSTTResponse.self, from: data)
        return TranscriptionResult(
            transcript: decoded.transcript,
            languageCode: decoded.language_code ?? languageCode,
            languageProbability: decoded.language_probability ?? 0
        )
    }
}

private struct SarvamSTTResponse: Decodable {
    let transcript: String
    let language_code: String?
    let language_probability: Double?
}

public enum SarvamError: Error, Sendable, Equatable {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case noAudioData
    case missingAPIKey
}

extension SarvamError {
    public var userMessage: String {
        switch self {
        case .invalidResponse:
            "Piko couldn't reach the transcription service. Check your connection."
        case .httpError(let code, _):
            "Transcription failed (error \(code)). Try again."
        case .noAudioData:
            "No audio was captured. Try speaking again."
        case .missingAPIKey:
            "Cloud transcription needs a Sarvam key. Add one in Settings › Voice engine."
        }
    }
}
#endif
