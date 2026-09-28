import Foundation
import PikoKit
import PikoBrain

/// Bridges the ask bar to the pocket harness: typed input routes exactly like spoken
/// input would (docs/HARNESS.md). Recall/suggest questions come back as an `AgentTurn`;
/// write-route input becomes a real dictation result — recorded, indexed, and delivered
/// to the transcript surface like any other.
@MainActor
final class AskCoordinator {
    private let agent: PikoAgent
    private let memory: any Memory
    private let brain: (any Brain)?
    private let channel: (any SessionChannel)?

    init(agent: PikoAgent,
         memory: any Memory,
         brain: (any Brain)? = nil,
         channel: (any SessionChannel)? = nil) {
        self.agent = agent
        self.memory = memory
        self.brain = brain
        self.channel = channel
    }

    /// Returns the turn to render, or nil when another surface (the transcript) is the
    /// responder — which is itself the answer for write-route input.
    func handle(_ input: String) async -> AgentTurn? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch AgentRouter.route(trimmed) {
        case .write:
            let profile = channel?.readState()?.profile ?? .message
            var shipped = trimmed
            if let brain {
                shipped = (try? await brain.rewrite(trimmed, profile: profile, lexicon: [], examples: [])) ?? trimmed
            }
            let result = CaptureResult(raw: trimmed, shipped: shipped, route: .write, profile: profile)
            await memory.record(result)
            await memory.indexNewResults()
            channel?.writeResult(result)
            channel?.post(.resultReady)
            return nil

        case .recall, .suggest:
            return await agent.turn(trimmed)
        }
    }

    /// Chip taps are follow-up turns ("Forget deck") — one tap, no typing.
    func chip(_ label: String) async -> AgentTurn? {
        await agent.chip(label)
    }
}
