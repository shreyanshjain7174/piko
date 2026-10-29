import Foundation
import PikoKit

/// "Free smart" organizer: Apple's on-device Foundation Models with structured output, when the
/// device supports Apple Intelligence. Any failure or unsupported device falls back to
/// `RuleOrganizer`, so filing never depends on the model being present.
public struct ModelOrganizer: Organizer {
    public struct Draft: Sendable, Equatable {
        public var kind: String
        public var text: String
        public var when: String?

        public init(kind: String, text: String, when: String?) {
            self.kind = kind
            self.text = text
            self.when = when
        }
    }

    public typealias Generate = @Sendable (_ transcript: String) async throws -> [Draft]
    public typealias Answer = @Sendable (_ instructions: String, _ prompt: String) async throws -> String

    private let generate: Generate
    private let answerer: Answer
    private let fallback = RuleOrganizer()

    public init(generate: Generate? = nil, answer: Answer? = nil) {
        self.generate = generate ?? Self.defaultGenerate
        self.answerer = answer ?? Self.defaultAnswer
    }

    public func organize(_ text: String, now: Date) async throws -> [DumpItem] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let drafts: [Draft]
        do {
            drafts = try await generate(text)
        } catch {
            return try await fallback.organize(text, now: now)
        }
        let items = drafts.compactMap { Self.item(from: $0, transcript: text, now: now) }
        return items.isEmpty ? try await fallback.organize(text, now: now) : items
    }

    public func answer(_ question: String, from history: [CaptureResult]) async throws -> String {
        guard !history.isEmpty else { return try await fallback.answer(question, from: history) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let notes = history.prefix(8)
            .map { "- (\(formatter.string(from: $0.createdAt))) \($0.shipped)" }
            .joined(separator: "\n")
        let instructions = """
        You are Piko, a warm, concise personal companion. Only use the notes below, which are \
        things the user said earlier. If the notes do not answer the question, say you couldn't \
        find it. Never invent facts. Answer in one or two short sentences.
        """
        do {
            let reply = try await answerer(instructions, "Notes:\n\(notes)\n\nQuestion: \(question)")
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? try await fallback.answer(question, from: history) : trimmed
        } catch {
            return try await fallback.answer(question, from: history)
        }
    }

    static func item(from draft: Draft, transcript: String, now: Date) -> DumpItem? {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isGrounded(text, in: transcript) else { return nil }
        let kind = DumpItem.Kind(rawValue: draft.kind.lowercased()) ?? .note
        var due: SpokenWhen?
        if kind == .reminder, let when = draft.when, isGrounded(when, in: transcript) {
            due = SpokenDate.resolve(when, context: transcript, now: now)
        }
        return DumpItem(kind: kind, text: RuleOrganizer.capitalized(text), due: due?.date,
                        dueHasTime: due?.hasTime ?? true, createdAt: now)
    }

    /// Faithfulness guard: most meaningful words of a filed item must have been spoken.
    static func isGrounded(_ text: String, in transcript: String) -> Bool {
        let spoken = Set(words(transcript))
        let filed = words(text).filter { $0.count > 3 }
        guard !filed.isEmpty else { return true }
        let heard = filed.filter { spoken.contains($0) }.count
        return Double(heard) / Double(filed.count) >= 0.6
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static let defaultGenerate: Generate = { transcript in
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return try await FoundationModelsOrganizing.file(transcript)
        }
        #endif
        throw PikoError.brainUnavailable("Foundation Models requires iOS 26")
    }

    private static let defaultAnswer: Answer = { instructions, prompt in
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return try await FoundationModelsInference.run(instructions: instructions, prompt: prompt)
        }
        #endif
        throw PikoError.brainUnavailable("Foundation Models requires iOS 26")
    }
}
