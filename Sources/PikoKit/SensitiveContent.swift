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

    private static let passLabel = try? NSRegularExpression(
        pattern: #"\bpass\b"#, options: [.caseInsensitive])
    private static let password = try? NSRegularExpression(
        pattern: #"\b(?:passwords?|passphrases?|passwd|pwd|passcodes?|secret(?: key)?)\b"#, options: [.caseInsensitive])
    private static let identityLabel = try? NSRegularExpression(
        pattern: #"\bpan\b"#, options: [.caseInsensitive])
    private static let identityWords = try? NSRegularExpression(
        pattern: #"\b(?:aadhaar|aadhar|pan (?:card|number)|ssn|social security|passport|(?:driver.?s? |driving )?licen[cs]e)\b"#, options: [.caseInsensitive])
    private static let aadhaar = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?<!\d[\s-])\d{4}[\s-]?\d{4}[\s-]?\d{4}(?![\s-]?\d|[A-Za-z])"#, options: [.caseInsensitive])
    private static let panFormat = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[A-Z]{5}\d{4}[A-Z](?![A-Za-z0-9])"#, options: [.caseInsensitive])
    private static let ssn = try? NSRegularExpression(
        pattern: #"(?<![\d])\d{3}-\d{2}-\d{4}(?![\d])"#, options: [.caseInsensitive])
    private static let paymentWords = try? NSRegularExpression(
        pattern: #"\b(?:payment|credit card|debit card|card number|cvv|cvc|expir(?:y|ation)|bank account|iban|routing number)\b"#, options: [.caseInsensitive])
    private static let authWords = try? NSRegularExpression(
        pattern: #"\b(?:otps?|totps?|mpins?|tpins?|pins?|2fa|one.time pass(?:word|code)|verification(?: code)?|auth(?:entication)? code|codes?)\b"#, options: [.caseInsensitive])
    private static let card = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?:\d[\s.\-]{0,2}){12,18}\d(?![A-Za-z0-9])"#)
    private static let camel = try? NSRegularExpression(pattern: #"([a-z0-9])([A-Z])"#)
    private static let separators = try? NSRegularExpression(pattern: #"[_/.\-]"#)

    public static func verdict(label: String, value: String) -> Verdict {
        guard value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return .blocked(.password) }

        guard let camel, let separators else { return .blocked(.password) }
        let withSpaces = camel.stringByReplacingMatches(
            in: label, range: NSRange(label.startIndex..., in: label), withTemplate: "$1 $2")
        let normalizedLabel = separators.stringByReplacingMatches(
            in: withSpaces, range: NSRange(withSpaces.startIndex..., in: withSpaces), withTemplate: " ")
        let text = normalizedLabel + " " + value
        if matches(Self.passLabel, in: normalizedLabel)
            || matches(Self.password, in: text) {
            return .blocked(.password)
        }
        if matches(Self.identityLabel, in: normalizedLabel)
            || matches(Self.identityWords, in: text)
            || matches(Self.aadhaar, in: text)
            || matches(Self.panFormat, in: text)
            || matches(Self.ssn, in: text) {
            return .blocked(.governmentID)
        }
        if matches(Self.paymentWords, in: text)
            || hasCardNumber(in: text) {
            return .blocked(.payment)
        }
        if matches(Self.authWords, in: text) {
            return .blocked(.authCode)
        }
        return .safe
    }

    private static func matches(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else { return true } // A broken detector must not let data through.
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func hasCardNumber(in text: String) -> Bool {
        guard let regex = Self.card else { return true }
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
