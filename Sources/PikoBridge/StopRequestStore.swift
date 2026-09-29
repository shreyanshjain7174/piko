import Foundation
import PikoKit

/// Durable stop request for the notch's Stop button. The intent runs in the widget
/// extension while the app is backgrounded, and Darwin notifications carry no delivery
/// guarantee there — the file is the source of truth; the app polls while a session is
/// live (the armed audio session keeps the process alive, so the poll always runs).
public struct StopRequest: Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date

    public init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
    }
}

public struct StopRequestStore: Sendable {
    private let fileURL: URL

    public init?(groupID: String = AppGroup.identifier) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else {
            return nil
        }
        fileURL = container.appendingPathComponent(AppGroup.stopRequestFile)
    }

    /// Test/support initializer for an explicitly controlled container.
    public init(containerURL: URL) {
        fileURL = containerURL.appendingPathComponent(AppGroup.stopRequestFile)
    }

    public func write(_ request: StopRequest) throws {
        let data = try JSONEncoder().encode(request)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Consumes whatever request is present. A stale one (older than `maxAge`) is read and
    /// discarded so a leftover tap can never end a session started afterwards.
    public func consumePending(now: Date = .now, maxAge: TimeInterval = 30) -> StopRequest? {
        guard let data = try? Data(contentsOf: fileURL),
              let request = try? JSONDecoder().decode(StopRequest.self, from: data) else {
            return nil
        }
        try? FileManager.default.removeItem(at: fileURL)
        guard now.timeIntervalSince(request.createdAt) <= maxAge else { return nil }
        return request
    }
}
