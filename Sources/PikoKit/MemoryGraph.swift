import Foundation

/// One thing Piko remembers — a person, a place, a recurring topic. Visible and
/// deletable in Settings ("What Piko remembers"); never synced anywhere.
public struct RememberedEntity: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var kind: Kind
    public var hitCount: Int
    public var lastSeen: Date

    public var id: String { name }

    public enum Kind: String, Codable, Sendable {
        case person, place, organization, topic

        public var symbolName: String {
            switch self {
            case .person: "person.fill"
            case .place: "mappin"
            case .organization: "building.2"
            case .topic: "sparkles"
            }
        }

        public var displayName: String {
            switch self {
            case .person: "person"
            case .place: "place"
            case .organization: "organization"
            case .topic: "topic"
            }
        }
    }

    public init(name: String, kind: Kind, hitCount: Int, lastSeen: Date = .now) {
        self.name = name
        self.kind = kind
        self.hitCount = hitCount
        self.lastSeen = lastSeen
    }
}

/// One gentle, time-aware line. Suggestions, never solutions — no exclamation marks,
/// no urgency, no lists (piko-ui-craft).
public struct Suggestion: Codable, Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// The bounded answer to "what does Piko know right now". Small by contract so it can
/// never grow into a prompt dump — it feeds one line of UI, not a context window.
public struct MemoryPacket: Codable, Sendable, Equatable {
    public var lastSaid: String?
    public var entities: [RememberedEntity]
    public var suggestion: Suggestion?

    public init(lastSaid: String? = nil, entities: [RememberedEntity] = [], suggestion: Suggestion? = nil) {
        self.lastSaid = lastSaid
        self.entities = entities
        self.suggestion = suggestion
    }
}

/// Pure suggestion derivation — no I/O, no clock reads, fully testable. The call site
/// supplies the hour and the entities; the engine decides whether Piko says anything
/// at all (usually it doesn't — quiet by default).
public enum SuggestionEngine {

    /// A recurring entity earns a mention; evening gets the "tonight" framing,
    /// morning the "pick it back up" one. People get a softer nudge than topics.
    public static func suggestion(for entities: [RememberedEntity], hour: Int) -> Suggestion? {
        guard let recurring = entities.first(where: { $0.hitCount >= 2 }) else { return nil }

        switch recurring.kind {
        case .person:
            return Suggestion(text: "You talk about \(recurring.name) a lot — maybe say hi.")
        case .topic, .place, .organization:
            if (17...23).contains(hour) {
                return Suggestion(text: "\(recurring.name) has come up a few times — tonight might be the night.")
            }
            if (5...11).contains(hour) {
                return Suggestion(text: "\(recurring.name) came up again — want to pick it back up?")
            }
            return nil
        }
    }
}

extension Memory {
    /// Tier-0 memory extraction over results recorded since the last watermark.
    /// Idempotent by construction; default implementations keep mocks and
    /// EphemeralMemory compiling without graph support.
    public func indexNewResults() async {}

    /// The transparency surface: everything Piko remembers, hottest first.
    public func rememberedEntities(limit: Int) async -> [RememberedEntity] { [] }

    /// cognee's `forget`, one swipe wide: removes the entity and every edge touching it.
    public func forget(entity name: String) async {}

    /// Interactive-grade recall. `nil` is a valid, honest answer.
    public func recall(query: String) async -> MemoryPacket? { nil }
}
