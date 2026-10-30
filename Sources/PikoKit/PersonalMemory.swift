import Foundation

/// Failures callers can distinguish from an absent fact, an unknown answer, or a SQLite error.
public enum PersonalMemoryError: Error, Equatable, Sendable {
    case invalidKey
    case invalidValue
    case invalidSourceTurn(Int64)
    case invalidExpectedLSN(Int64)
    case invalidConfidence
    case invalidTimestamp
    case invalidTurn
    case invalidEntity
    case invalidLimit(Int)
    case invalidQuery
    case sourceCaptureMissing(UUID)
    case sourceTurnMissing(Int64)
    case sourceTurnNotUser(Int64)
    case factConflict(key: String, expectedLSN: Int64?, actualLSN: Int64?)
    case entityMissing(String)
    case entityAlreadyExists(String)
    case revisionExhausted
}

/// A real utterance/reply/tool result in the append-only turns table. An LSN is never reused.
public struct MemoryTurn: Equatable, Sendable {
    public enum Role: String, Sendable {
        case user, assistant, tool, system
    }

    public let lsn: Int64
    public let session: UUID
    public let role: Role
    public let text: String
    public let at: Date

    public init(lsn: Int64, session: UUID, role: Role, text: String, at: Date) {
        self.lsn = lsn
        self.session = session
        self.role = role
        self.text = text
        self.at = at
    }

    public static func validate(text: String, at: Date) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.contains("\0"),
              text.utf8.count <= 65_536 else { throw PersonalMemoryError.invalidTurn }
        guard at.timeIntervalSince1970.isFinite else { throw PersonalMemoryError.invalidTimestamp }
    }
}

/// Values for a confirmed fact. A new fact must cite an existing user turn.
public struct MemoryFactInput: Equatable, Sendable {
    public let key: String
    public let value: String
    public let sourceTurn: Int64
    public let confidence: Double
    public let lastUsed: Date
    public let entityID: String?

    public init(key: String, value: String, sourceTurn: Int64, confidence: Double,
                lastUsed: Date = Date(timeIntervalSince1970: 0), entityID: String? = nil) {
        self.key = key
        self.value = value
        self.sourceTurn = sourceTurn
        self.confidence = confidence
        self.lastUsed = lastUsed
        self.entityID = entityID
    }

    public func validate() throws {
        try MemoryFact.validateKey(key)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("\0"),
              value.utf8.count <= 16_384 else { throw PersonalMemoryError.invalidValue }
        guard sourceTurn > 0 else { throw PersonalMemoryError.invalidSourceTurn(sourceTurn) }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw PersonalMemoryError.invalidConfidence
        }
        guard lastUsed.timeIntervalSince1970.isFinite else {
            throw PersonalMemoryError.invalidTimestamp
        }
        if let entityID { try MemoryEntity.validateID(entityID) }
    }
}

/// `lsn` is a per-key optimistic revision, not the LSN of the source turn.
/// Final-v1 has no fact tombstone or global fact sequence: forgetting and re-creating
/// the same key resets its revision. Do not reuse a cached revision across a forget.
/// A retained fact may have no source if its turn was expired by the existing FK policy.
public struct MemoryFact: Equatable, Sendable {
    public let key: String
    public let value: String
    public let lsn: Int64
    public let sourceTurn: Int64?
    public let confidence: Double
    public let lastUsed: Date
    public let entityID: String?

    public init(key: String, value: String, lsn: Int64, sourceTurn: Int64?,
                confidence: Double, lastUsed: Date, entityID: String?) {
        self.key = key
        self.value = value
        self.lsn = lsn
        self.sourceTurn = sourceTurn
        self.confidence = confidence
        self.lastUsed = lastUsed
        self.entityID = entityID
    }

    public static func validateKey(_ key: String) throws {
        guard key == key.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.contains("\0"),
              !key.isEmpty, key.utf8.count <= 512 else { throw PersonalMemoryError.invalidKey }
    }
}

/// Entity IDs remain text because the final-v1 schema also permits Contacts/photo IDs.
public struct MemoryEntity: Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let createdAt: Date
    public let aliases: [String]
    public let contactID: String?

    public init(id: String, name: String, kind: String, createdAt: Date = .now,
                aliases: [String] = [], contactID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.aliases = aliases
        self.contactID = contactID
    }

    public static func validateID(_ id: String) throws {
        guard id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.contains("\0"),
              !id.isEmpty, id.utf8.count <= 256 else { throw PersonalMemoryError.invalidEntity }
    }

    public func validate() throws {
        try Self.validateID(id)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.contains("\0"),
              name.utf8.count <= 256,
              !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !kind.contains("\0"),
              kind.utf8.count <= 64,
              aliases.count <= 32,
              aliases.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                   && !$0.contains("\0") && $0.utf8.count <= 256 }),
              contactID.map({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 512 }) ?? true
        else { throw PersonalMemoryError.invalidEntity }
        guard createdAt.timeIntervalSince1970.isFinite else {
            throw PersonalMemoryError.invalidTimestamp
        }
    }
}

/// Nil lists all; a supplied query must be nonempty and is a bound literal substring.
public enum PersonalMemoryQuery {
    public static func validated(_ query: String?, limit: Int) throws -> String? {
        guard (1...100).contains(limit) else { throw PersonalMemoryError.invalidLimit(limit) }
        guard let query else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), trimmed.utf8.count <= 256 else {
            throw PersonalMemoryError.invalidQuery
        }
        return trimmed
    }
}
