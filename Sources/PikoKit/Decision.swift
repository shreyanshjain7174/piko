import Foundation

/// The engine that actually produced this decision. A rule result never masquerades as a model result.
public enum EngineSource: Sendable, Equatable {
    case model
    case rules(reason: String)
}

/// An actual user turn and assistant reply in the current voice session, supplied by its owner.
public struct AssistantExchange: Sendable, Equatable {
    public let user: String
    public let reply: String

    public init(user: String, reply: String) {
        self.user = user
        self.reply = reply
    }
}

/// The model's previous question is untrusted context, not part of the user's request.
public struct PendingClarification: Sendable, Equatable {
    public let originalRequest: String
    public let question: String

    public init(originalRequest: String, question: String) {
        self.originalRequest = originalRequest
        self.question = question
    }
}

/// Candidate evidence, not instructions. The decider bounds every field before using it.
/// Supply facts and captures newest-first; only the last two exchanges are used.
public struct DecisionContext: Sendable, Equatable {
    public let facts: [MemoryFact]
    public let history: [CaptureResult]
    public let recent: [AssistantExchange]
    /// Trusted app preference; changes reply tone, never evidence or tool authorization.
    public let personality: PikoPersonality
    public let pendingClarification: PendingClarification?

    public init(facts: [MemoryFact] = [], history: [CaptureResult] = [],
                recent: [AssistantExchange] = [], personality: PikoPersonality = .warm,
                pendingClarification: PendingClarification? = nil) {
        self.facts = facts
        self.history = history
        self.recent = recent
        self.personality = personality
        self.pendingClarification = pendingClarification
    }
}

/// Actions are proposals. The caller must pass them through Conversation and its approval boundary.
public enum Decision: Sendable, Equatable {
    case answer(String)
    case ask(String)
    case act([ToolCall])
    case unknown(String)
}

public struct DecisionResult: Sendable, Equatable {
    public let decision: Decision
    public let source: EngineSource

    public init(decision: Decision, source: EngineSource) {
        self.decision = decision
        self.source = source
    }
}
