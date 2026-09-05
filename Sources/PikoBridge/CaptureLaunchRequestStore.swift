import Foundation
import PikoKit

/// Durable App Group handoff for an intent that may foreground a cold app process.
/// Darwin notifications provide the fast path; this file remains the source of truth.
public struct CaptureLaunchRequestStore: Sendable {
    private let fileURL: URL

    public init?(groupID: String = AppGroup.identifier) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else {
            return nil
        }
        fileURL = container.appendingPathComponent(AppGroup.captureRequestFile)
    }

    /// Test/support initializer for an explicitly controlled container.
    public init(containerURL: URL) {
        fileURL = containerURL.appendingPathComponent(AppGroup.captureRequestFile)
    }

    public func write(_ request: CaptureLaunchRequest) throws {
        let data = try JSONEncoder().encode(request)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Returns only a recent request. An expired request is removed so it cannot fire later.
    public func pending(
        now: Date = .now,
        maxAge: TimeInterval = 30
    ) -> CaptureLaunchRequest? {
        guard let data = try? Data(contentsOf: fileURL),
              let request = try? JSONDecoder().decode(CaptureLaunchRequest.self, from: data) else {
            return nil
        }

        guard now.timeIntervalSince(request.createdAt) <= maxAge else {
            clear(id: request.id)
            return nil
        }
        return request
    }

    /// Clear only the request the caller handled; a newer tap may already have replaced it.
    public func clear(id: UUID) {
        guard let data = try? Data(contentsOf: fileURL),
              let current = try? JSONDecoder().decode(CaptureLaunchRequest.self, from: data),
              current.id == id else {
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
