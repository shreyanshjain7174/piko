import Foundation

public enum PikoPersonality: String, Codable, CaseIterable, Sendable {
    case warm, calm, direct

    public var displayName: String {
        switch self {
        case .warm: "Warm and playful"
        case .calm: "Calm and gentle"
        case .direct: "Quiet and direct"
        }
    }

    public var greeting: String {
        switch self {
        case .warm: "Heeey... hi. What are we doing today?"
        case .calm: "Hey. I'm here. What can I help with?"
        case .direct: "Hi. What shall we get done?"
        }
    }
}

public enum PikoAttentionKind: Sendable {
    case greeting, completion
}

public enum PikoAttentionFeedback: String, Codable, Sendable {
    case engaged, dismissed
}

public struct PikoAttentionPattern: Codable, Equatable, Sendable {
    public private(set) var recent: [PikoAttentionFeedback]

    public init(recent: [PikoAttentionFeedback] = []) {
        self.recent = Array(recent.suffix(8))
    }

    public var engagedCount: Int { recent.filter { $0 == .engaged }.count }
    public var dismissedCount: Int { recent.count - engagedCount }

    public var permitsRoutineUpdate: Bool {
        recent.count < 3 || dismissedCount * 4 < recent.count * 3
    }

    public mutating func record(_ feedback: PikoAttentionFeedback) {
        recent = Array((recent + [feedback]).suffix(8))
    }

    private enum CodingKeys: String, CodingKey { case recent }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(recent: try container.decode([PikoAttentionFeedback].self, forKey: .recent))
    }
}

public struct PikoCompanionPreferences: Codable, Equatable, Sendable {
    public var personality: PikoPersonality
    public var quietMode: Bool
    public private(set) var greetings: PikoAttentionPattern
    public private(set) var completions: PikoAttentionPattern

    public init(personality: PikoPersonality = .warm, quietMode: Bool = false) {
        self.personality = personality
        self.quietMode = quietMode
        greetings = PikoAttentionPattern()
        completions = PikoAttentionPattern()
    }

    public mutating func record(_ feedback: PikoAttentionFeedback, for kind: PikoAttentionKind) {
        switch kind {
        case .greeting: greetings.record(feedback)
        case .completion: completions.record(feedback)
        }
    }

    public func shouldPresentRoutine(_ kind: PikoAttentionKind) -> Bool {
        guard !quietMode else { return false }
        switch kind {
        case .greeting: return greetings.permitsRoutineUpdate
        case .completion: return completions.permitsRoutineUpdate
        }
    }

    public mutating func resetLearning() {
        greetings = PikoAttentionPattern()
        completions = PikoAttentionPattern()
    }
}

public enum PikoCompanionStorageError: Error, Equatable, Sendable {
    case invalidStoredValue
    case unsupportedVersion(Int)
}

/// App preferences only: no transcripts, screen context or App Group storage.
@MainActor
public final class PikoCompanionStore {
    public static let preferencesKey = "PikoCompanionPreferences"
    public private(set) var preferences: PikoCompanionPreferences
    private let defaults: UserDefaults

    private struct Version: Decodable { let version: Int }
    private struct Snapshot: Codable {
        let version: Int
        let preferences: PikoCompanionPreferences
    }

    public init(defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        guard let stored = defaults.object(forKey: Self.preferencesKey) else {
            preferences = PikoCompanionPreferences()
            return
        }
        guard let data = stored as? Data else {
            throw PikoCompanionStorageError.invalidStoredValue
        }
        let decoder = JSONDecoder()
        let version = try decoder.decode(Version.self, from: data).version
        guard version == 1 else { throw PikoCompanionStorageError.unsupportedVersion(version) }
        preferences = try decoder.decode(Snapshot.self, from: data).preferences
    }

    public func save(_ preferences: PikoCompanionPreferences) throws {
        let data = try JSONEncoder().encode(Snapshot(version: 1, preferences: preferences))
        defaults.set(data, forKey: Self.preferencesKey)
        self.preferences = preferences
    }
}

/// A delayed synthesizer callback must not finish a newer utterance.
public struct PikoSpeechLifecycle: Sendable {
    private var current: UUID?

    public init() {}
    public var isSpeaking: Bool { current != nil }
    public mutating func begin(_ id: UUID) { current = id }
    public mutating func cancel() { current = nil }

    public mutating func finish(_ id: UUID) -> Bool {
        guard current == id else { return false }
        current = nil
        return true
    }
}
