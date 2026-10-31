import Foundation

/// Bounded, non-secret facts published by the app for the lightweight keyboard.
public struct SuggestionSnapshot: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let key: String
        public let label: String
        public let value: String
        public let factLSN: Int64
        public let sourceTurn: Int64?
    }

    public let version: Int
    /// Highest LSN among the entries in this snapshot (zero when empty).
    public let revision: Int64
    public let entries: [Entry]

    public static let empty = SuggestionSnapshot(version: 1, revision: 0, entries: [])

    /// Latest facts first, with a stable key tie-breaker; only the included facts affect revision.
    public static func build(from facts: [MemoryFact]) -> SuggestionSnapshot {
        let entries = facts.filter { fact in
            let key = fact.key
            return key == key.trimmingCharacters(in: .whitespacesAndNewlines)
                && !key.isEmpty && key.utf8.count <= 512 && fact.lsn > 0
                && !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                && !fact.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && SensitiveContent.verdict(label: key, value: fact.value) == .safe
        }.sorted {
            if $0.lsn != $1.lsn { return $0.lsn > $1.lsn }
            return $0.key < $1.key
        }.prefix(50).map {
            Entry(key: $0.key, label: $0.key, value: $0.value,
                  factLSN: $0.lsn, sourceTurn: $0.sourceTurn)
        }
        return SuggestionSnapshot(version: 1, revision: entries.map(\.factLSN).max() ?? 0,
                                  entries: entries)
    }
}
