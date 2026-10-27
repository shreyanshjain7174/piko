#if os(iOS)
import Foundation
import FoundationModels
import PikoKit

@available(iOS 26.0, *)
@Generable
struct PlannedStep {
    @Guide(description: "Which tool to use", .anyOf(ToolName.all))
    var tool: String
    @Guide(description: "Reminder or event title, note or journal text, check-in message, shortcut name, or search words. Use the speaker's words.")
    var text: String
    @Guide(description: "The exact date or time words the speaker said for this step, or empty if none")
    var when: String
}

@available(iOS 26.0, *)
@Generable
struct Plan {
    @Guide(description: "One step per separate thing the speaker asked for or said, in order. At most five. Never add anything they did not say.")
    var steps: [PlannedStep]
}

@available(iOS 26.0, *)
enum FoundationModelsPlanning {
    static func plan(_ request: String, tools: [ToolDescriptor]) async throws -> [ModelPlanner.Draft] {
        guard case .available = SystemLanguageModel.default.availability else {
            throw PikoError.brainUnavailable("unavailable")
        }
        let catalog = tools.map { "- \($0.name): \($0.summary)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
        You are Piko, a private on-device assistant. Turn what the user said into steps using \
        only these tools:
        \(catalog)
        Thoughts and ideas are notes. Feelings and reflections are journal entries. Keep their \
        words. Never invent tasks, names, dates or feelings.
        """)
        let response = try await session.respond(
            to: request, generating: Plan.self, options: GenerationOptions(samplingMode: .greedy))
        return response.content.steps.map {
            ModelPlanner.Draft(tool: $0.tool, text: $0.text, when: $0.when.isEmpty ? nil : $0.when)
        }
    }
}
#endif
