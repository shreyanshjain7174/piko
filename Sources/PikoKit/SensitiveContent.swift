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
    private static let paymentWords = try? NSRegularExpression(
        pattern: #"\b(?:payment|credit card|debit card|card number|cvv|cvc|expir(?:y|ation)|bank account|iban|routing number)\b"#, options: [.caseInsensitive])
    private static let authWords = try? NSRegularExpression(
        pattern: #"\b(?:otps?|totps?|mpins?|tpins?|pins?|2fa|one.time pass(?:word|code)|verification(?: code)?|auth(?:entication)? code|codes?)\b"#, options: [.caseInsensitive])
    private static let expiryLabel = try? NSRegularExpression(
        pattern: #"\bexp\b"#, options: [.caseInsensitive])
    private static let expiryValue = try? NSRegularExpression(
        pattern: #"^\s*(?:0[1-9]|1[0-2])[/.-](?:\d{2}|\d{4})\s*$"#)
    private static let splitOTP = try? NSRegularExpression(
        pattern: #"\bo\s+t\s+p\b"#, options: [.caseInsensitive])
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
        // Most snapshot entries have no digits; avoid allocating token groups on the poll path.
        let groups = value.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) })
            ? canonicalGroups(in: value) : []
        if matches(Self.identityLabel, in: normalizedLabel)
            || matches(Self.identityWords, in: text)
            || hasGovernmentNumber(in: groups) {
            return .blocked(.governmentID)
        }
        if matches(Self.paymentWords, in: text)
            || (matches(Self.expiryLabel, in: normalizedLabel)
                && matches(Self.expiryValue, in: value))
            || hasCardNumber(in: groups) {
            return .blocked(.payment)
        }
        if matches(Self.authWords, in: text)
            || matches(Self.splitOTP, in: normalizedLabel) {
            return .blocked(.authCode)
        }
        return .safe
    }

    private static func matches(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else { return true } // A broken detector must not let data through.
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Split at non-separators and separator runs longer than three. Each group
    /// preserves an alphanumeric boundary for structured ID formats.
    private static func canonicalGroups(in value: String) -> [[String]] {
        var sequences: [[String]] = []
        var groups: [String] = []
        var current = ""
        var separatorCount = 0
        func flush() {
            if !current.isEmpty { groups.append(current); current = "" }
            if !groups.isEmpty { sequences.append(groups); groups = [] }
        }
        for scalar in value.unicodeScalars {
            let isDigit = CharacterSet.decimalDigits.contains(scalar)
            if isDigit || CharacterSet.letters.contains(scalar) {
                if separatorCount > 3 { flush() }
                else if separatorCount > 0 && !current.isEmpty {
                    groups.append(current)
                    current = ""
                }
                separatorCount = 0
                if isDigit, let digit = Character(String(scalar)).wholeNumberValue,
                   (0...9).contains(digit) {
                    current.append(Character(UnicodeScalar(48 + digit)!))
                } else {
                    current.unicodeScalars.append(scalar)
                }
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar)
                        || ".-/_".unicodeScalars.contains(scalar) {
                separatorCount += 1
            } else {
                flush()
                separatorCount = 0
            }
        }
        flush()
        return sequences
    }

    private static func hasCardNumber(in sequences: [[String]]) -> Bool {
        for groups in sequences {
            var digits: [Int] = []
            var boundaries = [0]
            func check() -> Bool {
                guard digits.count >= 13 else { return false }
                // Only complete groups are candidate numbers: an invalid full card
                // must not be rescued by an accidental valid interior substring.
                for start in boundaries.dropLast() {
                    for end in boundaries.dropFirst() where (13...19).contains(end - start) {
                        var sum = 0
                        for offset in 0..<(end - start) {
                            let digit = digits[end - 1 - offset]
                            let doubled = offset.isMultiple(of: 2) ? digit : digit * 2
                            sum += doubled > 9 ? doubled - 9 : doubled
                        }
                        if sum.isMultiple(of: 10) { return true }
                    }
                }
                return false
            }
            for group in groups {
                if group.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    digits.append(contentsOf: group.compactMap(\.wholeNumberValue))
                    boundaries.append(digits.count)
                } else {
                    if check() { return true }
                    digits.removeAll(keepingCapacity: true)
                    boundaries = [0]
                }
            }
            if check() { return true }
        }
        return false
    }

    private static func hasGovernmentNumber(in sequences: [[String]]) -> Bool {
        for groups in sequences {
            // Start only on group boundaries, never inside a larger word.
            for start in groups.indices {
                var token = ""
                for group in groups[start...] {
                    token += group.uppercased()
                    if token.count >= 10 { break }
                }
                if token.count == 10 {
                    let chars = Array(token)
                    if chars[0..<5].allSatisfy({ $0.isASCII && $0.isLetter })
                        && chars[5..<9].allSatisfy({ $0.isASCII && $0.isNumber })
                        && chars[9].isASCII && chars[9].isLetter { return true }
                }
            }
            var digitGroups: [String] = []
            func check() -> Bool {
                let digits = digitGroups.joined().compactMap(\.wholeNumberValue)
                if digitGroups.map(\.count) == [3, 2, 4] || (digitGroups.count == 1 && digits.count == 9) {
                    return true // SSN format; the nine-digit unseparated form is sensitive too.
                }
                // Legacy fail-closed behavior for explicitly grouped 4-4-4 IDs:
                // Verifier literals are not Verhoeff-valid, but are still IDs.
                if digitGroups.map(\.count) == [4, 4, 4] { return true }
                guard digits.count >= 12 else { return false }
                for start in 0...(digits.count - 12) where (2...9).contains(digits[start]) {
                    if isVerhoeffValid(digits[start..<(start + 12)]) { return true }
                }
                return false
            }
            for group in groups {
                if group.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    digitGroups.append(group)
                } else {
                    if check() { return true }
                    digitGroups.removeAll(keepingCapacity: true)
                }
            }
            if check() { return true }
        }
        return false
    }

    private static let verhoeffD = [
        [0,1,2,3,4,5,6,7,8,9], [1,2,3,4,0,6,7,8,9,5],
        [2,3,4,0,1,7,8,9,5,6], [3,4,0,1,2,8,9,5,6,7],
        [4,0,1,2,3,9,5,6,7,8], [5,9,8,7,6,0,4,3,2,1],
        [6,5,9,8,7,1,0,4,3,2], [7,6,5,9,8,2,1,0,4,3],
        [8,7,6,5,9,3,2,1,0,4], [9,8,7,6,5,4,3,2,1,0],
    ]
    private static let verhoeffP = [
        [0,1,2,3,4,5,6,7,8,9], [1,5,7,6,2,8,3,0,9,4],
        [5,8,0,3,7,9,6,1,4,2], [8,9,1,6,0,4,3,5,2,7],
        [9,4,5,3,1,2,6,8,7,0], [4,2,8,6,5,7,3,9,0,1],
        [2,7,9,3,8,0,6,4,1,5], [7,0,4,6,9,1,3,2,5,8],
    ]

    private static func isVerhoeffValid(_ digits: ArraySlice<Int>) -> Bool {
        var checksum = 0
        for (index, digit) in digits.reversed().enumerated() {
            checksum = verhoeffD[checksum][verhoeffP[index % 8][digit]]
        }
        return checksum == 0
    }
}
