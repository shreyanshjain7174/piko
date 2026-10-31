import Foundation
import PikoKit

/// Atomic App Group handoff. The reader validates the complete file on every poll.
public struct SuggestionSnapshotStore: Sendable {
    private let fileURL: URL

    public init?(groupID: String = AppGroup.identifier) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ), let directory = try? SharedContainer.prepare(in: container) else { return nil }
        fileURL = directory.appendingPathComponent(AppGroup.suggestionsFile)
    }

    /// Test/support initializer for an explicitly controlled container.
    public init(containerURL: URL) {
        fileURL = containerURL.appendingPathComponent(AppGroup.suggestionsFile)
    }

    public func write(_ snapshot: SuggestionSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    /// No partial results: a single blocked or malformed entry invalidates the whole snapshot.
    public func read() -> SuggestionSnapshot {
        // Bound both I/O and decoding cost, including for files not produced by this writer.
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 128 * 1024,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(SuggestionSnapshot.self, from: data),
              snapshot.version == 1, snapshot.entries.count <= 50,
              Set(snapshot.entries.map(\.key)).count == snapshot.entries.count,
              snapshot.revision == (snapshot.entries.map(\.factLSN).max() ?? 0),
              snapshot.entries.allSatisfy({ entry in
                  let key = entry.key
                  return key == key.trimmingCharacters(in: .whitespacesAndNewlines)
                      && !key.isEmpty && key.utf8.count <= 512
                      && !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                      && !entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && entry.label.utf8.count <= 512
                      && !entry.label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                      && !entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && entry.factLSN > 0
                      && SensitiveContent.verdict(label: key + " " + entry.label,
                                                  value: entry.value) == .safe
              }) else { return .empty }
        return snapshot
    }
}
