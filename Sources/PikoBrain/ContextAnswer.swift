import Foundation
import PikoKit

/// Grounded answers for the narrow organized-person questions, never from free-form history.
public struct ContextAnswer: Sendable {
    public enum Reply: Equatable, Sendable {
        case unknown
        case grounded(value: String, quote: String, sourceTurnLSN: Int64, sourceDate: Date)
    }

    private let memory: any Memory

    public init(memory: any Memory) { self.memory = memory }

    public func answer(_ question: String) async throws -> Reply {
        guard let key = Self.key(for: question),
              let fact = try await memory.fact(forKey: key),
              let sourceLSN = fact.sourceTurn,
              let source = try await memory.turn(lsn: sourceLSN),
              source.role == .user,
              !fact.value.isEmpty, source.text.contains(fact.value)
        else { return .unknown }
        // Quotes are reconstructed from the cited user turn: the store records sourceTurn,
        // not proposal.quote. Fall back to the full verbatim utterance for custom proposals.
        let quote = RuleContextProposer().propose(from: source)
            .first { $0.key == key && $0.value == fact.value }?.quote ?? source.text
        guard source.text.contains(quote), quote.contains(fact.value) else { return .unknown }
        return .grounded(value: fact.value, quote: quote,
                         sourceTurnLSN: source.lsn, sourceDate: source.at)
    }

    public static func recognizes(_ question: String) -> Bool { key(for: question) != nil }

    private static func key(for question: String) -> String? {
        guard question.utf8.count <= 256, !question.contains("\0") else { return nil }
        let edge = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?"))
        let text = question.trimmingCharacters(in: edge)
        let patterns: [(String, String)] = [
            (#"^what does ([\p{L}]+) drink$"#, "usual"),
            (#"^what does ([\p{L}]+) usually have$"#, "usual"),
            (#"^what[\u0027’]s ([\p{L}]+)[\u0027’]s usual$"#, "usual"),
            (#"^when do I meet ([\p{L}]+)$"#, "meets"),
        ]
        for (pattern, suffix) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return "person/" + text[range].lowercased() + "/" + suffix
        }
        return nil
    }
}
