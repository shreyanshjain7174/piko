import Foundation
import PikoKit

/// Narrow, deterministic extraction. All callers must pass its output through ProposalGate.
public struct RuleContextProposer: ContextProposer {
    public init() {}

    public func propose(from source: MemoryTurn) -> [ContextProposal] {
        guard source.role == .user else { return [] }
        let text = source.text
        if case .remember(let key, let subject, let value) = PersonalIntent.parse(text) {
            return [ContextProposal(kind: .fact, entityName: nil, key: key, label: subject,
                                    value: value, quote: text, sourceTurn: source)]
        }

        var proposals: [ContextProposal] = []
        var name: String?
        for match in matches(#"\b([\p{Lu}][\p{L}]+)[\u0027’]s usual is ([^,.!?]+)"#, in: text) {
            let person = match.captures[0]
            let value = match.captures[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            name = person
            proposals.append(ContextProposal(kind: .preference, entityName: person,
                                             key: "person/\(person.lowercased())/usual", label: "usual",
                                             value: value,
                                             quote: match.quote.trimmingCharacters(in: .whitespacesAndNewlines),
                                             sourceTurn: source))
        }
        for match in matches(#"\b([\p{Lu}][\p{L}]+) is my ([\p{L}]+)\b"#, in: text) {
            let person = match.captures[0]
            name = person
            proposals.append(ContextProposal(kind: .person, entityName: person,
                                             key: "person/\(person.lowercased())/relation",
                                             label: "relation", value: match.captures[1],
                                             quote: match.quote, sourceTurn: source))
        }
        if name == nil {
            name = matches(#"\b(?:with|meet) ([\p{Lu}][\p{L}]+)\b"#, in: text)
                .first?.captures.first
                ?? matches(#"\b([\p{Lu}][\p{L}]+) and I\b"#, in: text)
                    .first?.captures.first
        }
        if let name {
            for match in matches(#"\bwe meet (?:on )?(Mondays|Tuesdays|Wednesdays|Thursdays|Fridays|Saturdays|Sundays)\b"#, in: text, options: [.caseInsensitive]) {
                proposals.append(ContextProposal(kind: .routine, entityName: name,
                                                 key: "person/\(name.lowercased())/meets",
                                                 label: "meets", value: match.captures[0],
                                                 quote: match.quote, sourceTurn: source))
            }
        }
        return proposals
    }

    private func matches(_ pattern: String, in text: String,
                         options: NSRegularExpression.Options = []) -> [(quote: String, captures: [String])] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let whole = Range(match.range, in: text) else { return nil }
            let captures = (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            return (String(text[whole]), captures)
        }
    }
}
