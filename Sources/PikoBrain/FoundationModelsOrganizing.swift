#if os(iOS)
import Foundation
import FoundationModels
import PikoKit

@available(iOS 26.0, *)
@Generable
struct FiledThought {
    @Guide(description: "reminder for something to do, note for an idea or fact, journal for a feeling or reflection",
           .anyOf(["reminder", "note", "journal"]))
    var kind: String
    @Guide(description: "The item in the speaker's own words, short. Reminders start with a verb. No dates here.")
    var text: String
    @Guide(description: "The exact date or time words the speaker said for this reminder, or empty if none")
    var when: String
}

@available(iOS 26.0, *)
@Generable
struct Filing {
    @Guide(description: "Each separate thing the speaker said, in order. Never add anything they did not say.")
    var items: [FiledThought]
}

@available(iOS 26.0, *)
enum FoundationModelsOrganizing {
    static func file(_ transcript: String) async throws -> [ModelOrganizer.Draft] {
        guard case .available = SystemLanguageModel.default.availability else {
            throw PikoError.brainUnavailable("unavailable")
        }
        let session = LanguageModelSession(instructions: """
        You file a person's spoken brain-dump into separate items. Split it into distinct \
        thoughts. Keep their words. Never invent tasks, names, dates or feelings.
        """)
        let response = try await session.respond(
            to: transcript, generating: Filing.self, options: GenerationOptions(samplingMode: .greedy))
        return response.content.items.map {
            ModelOrganizer.Draft(kind: $0.kind, text: $0.text, when: $0.when.isEmpty ? nil : $0.when)
        }
    }
}
#endif
