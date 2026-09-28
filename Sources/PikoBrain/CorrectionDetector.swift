import Foundation

public enum CorrectionDetector {

    public struct CorrectionResult: Sendable {
        public let text: String
        public let corrections: [Correction]
    }

    public struct Correction: Sendable {
        public let kind: Kind
        public let original: String
        public let replacement: String

        public enum Kind: Sendable {
            case selfCorrection
            case deletion
            case fillerRemoval
            case formatting
        }
    }

    private static let deletionPatterns: [String] = [
        "delete that",
        "scratch that",
        "remove that",
        "erase that",
        "undo that",
        "take that back",
    ]

    private static let correctionPrefixes: [String] = [
        "actually",
        "i mean",
        "wait",
        "sorry",
        "correction",
        "no no",
        "no,",
    ]

    private static let fillerWords: Set<String> = [
        "um", "uh", "umm", "uhh", "hmm", "hm",
        "er", "erm", "ah", "ahh",
        "you know", "i mean", "kind of", "sort of",
        "basically", "literally",
    ]

    private static let formattingCommands: [String: String] = [
        "new line": "\n",
        "new paragraph": "\n\n",
        "period": ".",
        "full stop": ".",
        "comma": ",",
        "question mark": "?",
        "exclamation mark": "!",
        "exclamation point": "!",
        "colon": ":",
        "semicolon": ";",
        "open quote": "\"",
        "close quote": "\"",
        "open parenthesis": "(",
        "close parenthesis": ")",
    ]

    public static func process(_ text: String) -> CorrectionResult {
        var working = text
        var corrections: [Correction] = []

        let lower = working.lowercased()
        for pattern in deletionPatterns {
            if lower.hasSuffix(pattern) {
                let beforeCommand = working.dropLast(pattern.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let (kept, deleted) = removingLastSentence(from: String(beforeCommand))
                working = kept
                corrections.append(Correction(kind: .deletion, original: deleted, replacement: ""))
                return CorrectionResult(text: working, corrections: corrections)
            }
        }

        for (command, replacement) in formattingCommands {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: command))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(working.startIndex..., in: working)
                let matches = regex.matches(in: working, range: range)
                for match in matches.reversed() {
                    guard let swiftRange = Range(match.range, in: working) else { continue }
                    let original = String(working[swiftRange])
                    working.replaceSubrange(swiftRange, with: replacement)
                    corrections.append(Correction(kind: .formatting, original: original, replacement: replacement))
                }
            }
        }

        for prefix in correctionPrefixes {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: prefix))\\s+"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(working.startIndex..., in: working)
            if let match = regex.firstMatch(in: working, range: range),
               let swiftRange = Range(match.range, in: working) {
                let correctionStart = swiftRange.upperBound
                let correctedPart = String(working[correctionStart...]).trimmingCharacters(in: .whitespaces)
                let beforeCorrection = String(working[..<swiftRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !correctedPart.isEmpty {
                    working = beforeCorrection.isEmpty ? correctedPart : beforeCorrection + " " + correctedPart
                    corrections.append(Correction(kind: .selfCorrection, original: prefix, replacement: correctedPart))
                }
            }
        }

        var words = working.components(separatedBy: .whitespaces)
        var removedFillers: [String] = []
        words.removeAll { word in
            let lower = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if fillerWords.contains(lower) {
                removedFillers.append(word)
                return true
            }
            return false
        }
        if !removedFillers.isEmpty {
            working = words.joined(separator: " ")
            for filler in removedFillers {
                corrections.append(Correction(kind: .fillerRemoval, original: filler, replacement: ""))
            }
        }

        working = working.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CorrectionResult(text: working, corrections: corrections)
    }

    /// Splits `text` into (everything up to and including the second-to-last sentence
    /// terminator, the trailing sentence itself). A terminator that is the text's very
    /// last character belongs to the sentence being deleted, not a prior boundary — so
    /// the search for "where the last sentence starts" skips over it.
    private static func removingLastSentence(from text: String) -> (kept: String, deleted: String) {
        guard !text.isEmpty else { return ("", "") }
        let terminators = CharacterSet(charactersIn: ".!?")
        let searchEnd = text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?")
            ? text.index(before: text.endIndex)
            : text.endIndex

        var cursor = searchEnd
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            if String(text[previous]).rangeOfCharacter(from: terminators) != nil {
                let kept = String(text[text.startIndex..<cursor]).trimmingCharacters(in: .whitespacesAndNewlines)
                let deleted = String(text[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (kept, deleted)
            }
            cursor = previous
        }
        return ("", text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
