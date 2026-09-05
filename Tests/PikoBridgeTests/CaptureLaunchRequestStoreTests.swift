import Foundation
import PikoBridge
import PikoKit
import Testing

@Suite("Capture launch request store")
struct CaptureLaunchRequestStoreTests {
    @Test func roundTripAndMatchingClear() throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let store = CaptureLaunchRequestStore(containerURL: container)
        let request = CaptureLaunchRequest(createdAt: Date(timeIntervalSince1970: 100))
        try store.write(request)

        #expect(store.pending(now: Date(timeIntervalSince1970: 110)) == request)
        store.clear(id: UUID())
        #expect(store.pending(now: Date(timeIntervalSince1970: 110)) == request)
        store.clear(id: request.id)
        #expect(store.pending(now: Date(timeIntervalSince1970: 110)) == nil)
    }

    @Test func newerRequestSurvivesOlderClear() throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let store = CaptureLaunchRequestStore(containerURL: container)
        let older = CaptureLaunchRequest(createdAt: Date(timeIntervalSince1970: 100))
        let newer = CaptureLaunchRequest(createdAt: Date(timeIntervalSince1970: 101))
        try store.write(older)
        try store.write(newer)

        store.clear(id: older.id)
        #expect(store.pending(now: Date(timeIntervalSince1970: 110)) == newer)
    }

    @Test func staleRequestIsRejectedAndRemoved() throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let store = CaptureLaunchRequestStore(containerURL: container)
        let request = CaptureLaunchRequest(createdAt: Date(timeIntervalSince1970: 100))
        try store.write(request)

        #expect(store.pending(now: Date(timeIntervalSince1970: 131)) == nil)
        #expect(store.pending(now: Date(timeIntervalSince1970: 110)) == nil)
    }

    private func temporaryContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
