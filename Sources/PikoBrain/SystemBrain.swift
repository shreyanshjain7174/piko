import Foundation
import PikoKit

/// The v0.1 brain: Apple's on-device Foundation Models.
///
/// Two jobs, two budgets. `route` must stay off the fast path — it runs a cheap prefilter and
/// only escalates to the model when genuinely unsure. `rewrite` runs once, after the user stops
/// speaking, with a 600 ms target (see docs/SPIKES.md, spike 5).
public struct SystemBrain: Brain {

    public typealias Inference = @Sendable (_ instructions: String, _ prompt: String) async throws -> String

    private let budget: Duration
    private let inference: Inference

    public init(budget: Duration = .milliseconds(600), inference: Inference? = nil) {
        self.budget = budget
        self.inference = inference ?? Self.defaultInference
    }

    private static let defaultInference: Inference = { instructions, prompt in
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return try await FoundationModelsInference.run(instructions: instructions, prompt: prompt)
        }
        #endif
        throw PikoError.brainUnavailable("Foundation Models requires iOS 26")
    }

    // MARK: routing

    /// Utterances that are almost certainly commands. Cheap, deterministic, no model involved.
    private static let commandStarters = [
        "remind me", "set a timer", "add to", "schedule", "create a", "make a note",
        "delete", "cancel", "open ", "text ", "call "
    ]
    private static let recallStarters = [
        "what did i", "when did i", "find where", "search for", "show me my", "remind me what"
    ]

    public func route(_ text: String) async -> Route {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.recallStarters.contains(where: lowered.hasPrefix) { return .recall }
        if Self.commandStarters.contains(where: lowered.hasPrefix) { return .command }
        // v0.1 ships write-only. v0.2 escalates the ambiguous middle to a tiny routing model
        // here — never to the rewrite model. See docs/MODELS.md.
        return .write
    }

    // MARK: rewriting

    public func rewrite(_ text: String,
                        profile: Profile,
                        lexicon: [String],
                        examples: [EditPair]) async throws -> String {
        let instructions = Self.instructions(profile, lexicon)
        let prompt = Self.prompt(text, examples)
        let inference = self.inference
        let cleaned = try await withRewriteBudget(budget) {
            try await inference(instructions, prompt)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The system prompt. Faithfulness first: a rewriter that invents a sentence in the user's
    /// voice is worse than one that leaves an "um" in. See docs/MODELS.md.
    static func instructions(_ profile: Profile, _ lexicon: [String]) -> String {
        """
        You clean up dictated speech into text the speaker would have typed.

        Rules, in priority order:
        1. Never add information the speaker did not say. Never invent names, numbers or dates.
        2. Remove fillers and false starts. Keep the speaker's own words wherever possible.
        3. Add punctuation and capitalisation.
        4. Match this tone: \(profile.styleHint)
        5. Output only the cleaned text. No preamble, no quotes, no explanation.

        These words are spelled this way for this speaker: \(lexicon.prefix(40).joined(separator: ", "))
        """
    }

    static func prompt(_ text: String, _ examples: [EditPair]) -> String {
        let shots = examples.prefix(3).map {
            "Heard: \($0.raw)\nWanted: \($0.final)"
        }.joined(separator: "\n\n")
        return shots.isEmpty ? "Heard: \(text)\nWanted:" : "\(shots)\n\nHeard: \(text)\nWanted:"
    }
}

/// Deterministic brain for tests and the fast Simulator loop.
public struct MockBrain: Brain {
    public init() {}
    public func route(_ text: String) async -> Route { .write }
    public func rewrite(_ text: String, profile: Profile,
                        lexicon: [String], examples: [EditPair]) async throws -> String {
        var out = text
        for filler in ["um ", "uh ", "like ", "you know "] {
            out = out.replacingOccurrences(of: filler, with: "", options: .caseInsensitive)
        }
        out = out.trimmingCharacters(in: .whitespaces)
        if let first = out.first { out.replaceSubrange(out.startIndex...out.startIndex,
                                                      with: String(first).uppercased()) }
        if let last = out.last, !".!?".contains(last) { out.append(".") }
        return out
    }
}
