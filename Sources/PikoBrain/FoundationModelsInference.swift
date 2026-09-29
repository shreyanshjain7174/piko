#if os(iOS)
import Foundation
import FoundationModels
import PikoKit

@available(iOS 27.0, *)
enum FoundationModelsInference {
    static func run(instructions: String, prompt: String) async throws -> String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                throw PikoError.brainUnavailable("deviceNotEligible")
            case .appleIntelligenceNotEnabled:
                throw PikoError.brainUnavailable("appleIntelligenceNotEnabled")
            case .modelNotReady:
                throw PikoError.brainUnavailable("modelNotReady")
            @unknown default:
                throw PikoError.brainUnavailable("unavailable")
            }
        }
        do {
            // Fresh local session per call. Not retained after return or timeout.
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(sampling: .greedy)
            let response = try await session.respond(to: prompt, options: options)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as LanguageModelSession.GenerationError {
            throw PikoError.brainUnavailable(mapGenerationError(error))
        }
    }

    private static func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize(let context):
            return "exceededContextWindowSize: \(context.debugDescription)"
        case .assetsUnavailable(let context):
            return "assetsUnavailable: \(context.debugDescription)"
        case .guardrailViolation(let context):
            return "guardrailViolation: \(context.debugDescription)"
        case .unsupportedGuide(let context):
            return "unsupportedGuide: \(context.debugDescription)"
        case .unsupportedLanguageOrLocale(let context):
            return "unsupportedLanguageOrLocale: \(context.debugDescription)"
        case .decodingFailure(let context):
            return "decodingFailure: \(context.debugDescription)"
        case .rateLimited(let context):
            return "rateLimited: \(context.debugDescription)"
        case .concurrentRequests(let context):
            return "concurrentRequests: \(context.debugDescription)"
        case .refusal(_, let context):
            return "refusal: \(context.debugDescription)"
        @unknown default:
            return "generationError: \(String(describing: error))"
        }
    }
}
#endif
