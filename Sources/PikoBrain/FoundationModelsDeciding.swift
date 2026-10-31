#if os(iOS)
import Foundation
import FoundationModels
import PikoKit

@available(iOS 26.0, *)
@Generable
struct DecisionStep {
    @Guide(description: "The name of an offered action tool. Never use a memory tool.")
    var tool: String
    @Guide(description: "Action text grounded in the current request and quoted evidence, not a new task.")
    var text: String
    @Guide(description: "Exact date/time words from the current request only, or empty.")
    var when: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedDecision {
    @Guide(description: "One of answer, ask, act or unknown", .anyOf(["answer", "ask", "act", "unknown"]))
    var kind: String
    @Guide(description: "A short answer, one question ending in ?, or an honest unknown. Empty for act.")
    var reply: String
    @Guide(description: "For act only, at most five steps using the offered tools. Empty otherwise.")
    var steps: [DecisionStep]
}

@available(iOS 26.0, *)
enum FoundationModelsDeciding {
    static func generate(instructions: String, prompt: String) async throws -> ModelDecider.Draft {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: throw PikoError.brainUnavailable("deviceNotEligible")
            case .appleIntelligenceNotEnabled: throw PikoError.brainUnavailable("appleIntelligenceNotEnabled")
            case .modelNotReady: throw PikoError.brainUnavailable("modelNotReady")
            @unknown default: throw PikoError.brainUnavailable("unavailable")
            }
        }
        // A fresh session for each bounded request: no retained, unbounded model transcript.
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: GeneratedDecision.self,
                                                 options: GenerationOptions(samplingMode: .greedy))
        return ModelDecider.Draft(kind: response.content.kind, reply: response.content.reply,
                                  steps: response.content.steps.map {
            .init(tool: $0.tool, text: $0.text, when: $0.when.isEmpty ? nil : $0.when)
        })
    }
}
#endif
