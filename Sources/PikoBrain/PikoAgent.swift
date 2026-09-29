import Foundation
import PikoKit

/// One completed harness turn. Small by contract: one line, at most two chips, an
/// optional voice line, and the mood the pet should wear afterwards.
public struct AgentTurn: Codable, Sendable, Equatable {
    public var line: String
    public var chips: [String]
    public var speak: Bool
    public var mood: PikoMood

    public init(line: String, chips: [String] = [], speak: Bool = false, mood: PikoMood = .calm) {
        self.line = line
        self.chips = chips
        self.speak = speak
        self.mood = mood
    }
}

/// Deterministic tier-0 router — the pocket harness's "planner". One utterance, one
/// intention; ambiguous always falls through to write, because dictation is the product.
public enum AgentRouter {

    public enum RouteKind: Equatable, Sendable {
        case recall(query: String)
        case suggest
        case write
    }

    private static let recallMarkers: Set<String> = [
        "remember", "recall", "what did i", "what have i", "know about",
        "tell me about", "said about", "mentioned",
    ]

    private static let suggestMarkers: Set<String> = [
        "suggest", "what should i", "any idea", "bored",
    ]

    public static func route(_ utterance: String) -> RouteKind {
        let lowered = utterance.localizedLowercase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return .write }

        if suggestMarkers.contains(where: { lowered.contains($0) }) { return .suggest }
        if let marker = recallMarkers.first(where: { lowered.contains($0) }) {
            // Strip the marker and its trailing connective so the query is the subject.
            var query = lowered
            if let range = query.range(of: marker) {
                query = String(query[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ?about"))
            }
            if query.count < 2 { query = lowered }
            return .recall(query: query)
        }
        return .write
    }
}

/// The pocket harness: one turn per invocation, deterministic tier-0 intelligence,
/// the memory graph as its only grounding. Foundation Models slots in later behind
/// this same interface (docs/HARNESS.md tier ladder).
public actor PikoAgent {
    private let memory: any Memory

    public init(memory: any Memory) {
        self.memory = memory
    }

    public func turn(_ utterance: String, hour: Int = Calendar.current.component(.hour, from: Date())) async -> AgentTurn? {
        switch AgentRouter.route(utterance) {
        case .write:
            // Dictation owns this input; the capture pipeline is the responder.
            return nil

        case .suggest:
            let packet = await memory.recall(query: "")
            guard let suggestion = SuggestionEngine.suggestion(for: packet?.entities ?? [], hour: hour) else {
                return AgentTurn(line: "Nothing on my mind yet. Talk to me and I'll notice.", mood: .calm)
            }
            return AgentTurn(line: suggestion.text, chips: [], speak: true, mood: .happy)

        case .recall(let query):
            let packet = await memory.recall(query: query)
            guard let packet, !packet.entities.isEmpty else {
                return AgentTurn(
                    line: "Nothing yet — tell me about it and I'll remember.",
                    chips: [],
                    mood: .fresh
                )
            }
            let names = packet.entities.prefix(3).map { $0.name }.joined(separator: ", ")
            var chips: [String] = []
            if let first = packet.entities.first(where: { $0.hitCount >= 2 }) {
                chips.append("Forget \(first.name)")
            }
            return AgentTurn(
                line: "You've mentioned \(names) — \(packet.lastSaid ?? "a while ago").",
                chips: chips,
                mood: .happy
            )
        }
    }

    /// Chip tap = a whole follow-up turn, no typing required.
    public func chip(_ label: String) async -> AgentTurn? {
        guard label.lowercased().starts(with: "forget ") else { return nil }
        let name = String(label.dropFirst("forget ".count))
        await memory.forget(entity: name)
        return AgentTurn(line: "Done — \(name) is forgotten.", chips: [], mood: .calm)
    }
}
