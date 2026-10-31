import Foundation

/// Conservative filter for personal context; never include rejected values in diagnostics.
public enum SensitiveContent {
    public enum Category: Equatable, Sendable {
        case password, payment, governmentID, authCode
    }

    public enum Verdict: Equatable, Sendable {
        case safe
        case blocked(Category)
    }

    public static func verdict(label: String, value: String) -> Verdict {
        guard value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return .blocked(.password) }

        let text = label + " " + value
        if matches(#"\b(?:password|passphrase|passwd|pwd|secret(?: key)?)\b"#, in: text) {
            return .blocked(.password)
        }
        if matches(#"\b(?:aadhaar|aadhar|pan (?:card|number)|ssn|social security|passport|(?:driver.?s? |driving )?licen[cs]e)\b"#, in: text)
            || matches(#"\bPAN\b"#, in: text, options: [])
            || matches(#"(?<![A-Za-z0-9])(?<!\d[ -])\d{4}\s?\d{4}\s?\d{4}(?![ -]?\d|[A-Za-z])"#, in: text)
            || matches(#"(?<![A-Za-z0-9])[A-Z]{5}\d{4}[A-Z](?![A-Za-z0-9])"#, in: text, options: [])
            || matches(#"(?<![\d])\d{3}-\d{2}-\d{4}(?![\d])"#, in: text) {
            return .blocked(.governmentID)
        }
        if matches(#"\b(?:payment|credit card|debit card|card number|cvv|cvc|expir(?:y|ation)|bank account|iban|routing number)\b"#, in: text)
            || hasCardNumber(in: text) {
            return .blocked(.payment)
        }
        if matches(#"\b(?:otp|one.time pass(?:word|code)|verification(?: code)?|auth(?:entication)? code|pin|code)\b"#, in: text) {
            return .blocked(.authCode)
        }
        return .safe
    }

    private static func matches(_ pattern: String, in text: String,
                                options: NSRegularExpression.Options = [.caseInsensitive]) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return true // A broken detector must not let data through.
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func hasCardNumber(in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])(?:\d[ -]?){12,18}\d(?![A-Za-z0-9])"#
        ) else { return true }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { return true }
            let digits = text[range].compactMap { $0.wholeNumberValue }
            guard (13...19).contains(digits.count) else { continue }
            var sum = 0
            for (index, digit) in digits.reversed().enumerated() {
                let doubled = index.isMultiple(of: 2) ? digit : digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
            if sum.isMultiple(of: 10) { return true }
        }
        return false
    }
}
