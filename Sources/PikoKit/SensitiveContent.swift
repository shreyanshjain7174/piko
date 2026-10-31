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
        pattern: #"\b(?:passwords?|passphrases?|passwd|pwd|passcodes?|pw|pswd|pass word|secret(?: key)?)\b"#, options: [.caseInsensitive])
    private static let identityLabel = try? NSRegularExpression(
        pattern: #"\bpan\b"#, options: [.caseInsensitive])
    private static let identityWords = try? NSRegularExpression(
        pattern: #"\b(?:aadhaar|aadhar|pan (?:card|number)|ssn|social security|passport|(?:driver.?s? |driving )?licen[cs]e)\b"#, options: [.caseInsensitive])
    private static let paymentWords = try? NSRegularExpression(
        pattern: #"\b(?:payment|credit card|debit card|card number|cvv2?|cvc|expir(?:y|ation|es)|valid thru|bank account|iban|routing number)\b"#, options: [.caseInsensitive])
    private static let authWords = try? NSRegularExpression(
        pattern: #"\b(?:otps?\d*|totps?|mpins?|tpins?|ipins?|pins?|2fa|one.time pass(?:word|code)|verification(?: code)?|auth(?:entication)? code|codes?)\b"#, options: [.caseInsensitive])
    private static let expiryLabel = try? NSRegularExpression(
        pattern: #"\bexp\b"#, options: [.caseInsensitive])
    private static let expiryValue = try? NSRegularExpression(
        pattern: #"^\s*(?:0[1-9]|1[0-2])[/.-](?:\d{2}|\d{4})\s*$"#)
    private static let splitOTP = try? NSRegularExpression(
        pattern: #"\bo\s+t\s+p\b"#, options: [.caseInsensitive])
    private static let credentialLabel = try? NSRegularExpression(
        pattern: #"\b(?:log\s*in|sign\s*in|credentials?)\b"#, options: [.caseInsensitive])
    private static let securityAnswer = try? NSRegularExpression(
        pattern: #"\b(?:mother.?s? maiden name|first pet|first school)\b"#, options: [.caseInsensitive])
    private static let sentCode = try? NSRegularExpression(
        pattern: #"\b(?:the\s+)?[4-8][ -]?digit\s+(?:number|code)\b.{0,48}\b(?:sent|texted)\b"#, options: [.caseInsensitive])
    private static let voterID = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[A-Z]{3}[0-9]{7}(?![A-Za-z0-9])"#, options: [.caseInsensitive])
    // Current state/UT codes plus OR, UA and CT: legacy licences can remain valid.
    // Require RTO (2), issuance year (4) and serial (7); a mobile has only 10 digits.
    private static let drivingID = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?:AN|AP|AR|AS|BR|CH|CG|DD|DL|GA|GJ|HR|HP|JK|JH|KA|KL|LA|LD|MP|MH|MN|ML|MZ|NL|OD|PY|PB|RJ|SK|TN|TS|TR|UP|UK|WB|OR|UA|CT)[ ./_-]?[0-9]{2}[ ./_-]?(?:19|20)[0-9]{2}[ ./_-]?[0-9]{7}(?![A-Za-z0-9])"#, options: [.caseInsensitive])
    private static let dlLabel = try? NSRegularExpression(pattern: #"\bdl\b"#, options: [.caseInsensitive])
    // Only UPI-like handles are blocked without a label; ordinary emails remain useful context.
    private static let upiHandle = try? NSRegularExpression(
        pattern: #"(?<![\w.+-])[\w.-]+@(?:ok[a-z]+|ybl|paytm|upi|ibl|axl)(?![a-z]|\.[a-z])"#, options: [.caseInsensitive])
    private static let upiID = try? NSRegularExpression(
        pattern: #"(?<![\w.+-])[\w.-]+@[a-z]+(?![a-z]|\.[a-z])"#, options: [.caseInsensitive])
    private static let upiWords = try? NSRegularExpression(
        pattern: #"\bupi(?:\s+id)?\b"#, options: [.caseInsensitive])
    private static let timeRange = try? NSRegularExpression(
        pattern: #"(?<![0-9])(?:[01]?[0-9]|2[0-3])[.:][0-5][0-9]\s*[-–—]\s*(?:[01]?[0-9]|2[0-3])[.:][0-5][0-9](?![0-9])"#)
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
            || matches(Self.password, in: text)
            || matches(Self.credentialLabel, in: normalizedLabel)
            || matches(Self.securityAnswer, in: text) {
            return .blocked(.password)
        }
        // Most snapshot entries have no digits; avoid allocating token groups on the poll path.
        let withoutTimes = timeRange?.stringByReplacingMatches(
            in: value, range: NSRange(value.startIndex..., in: value), withTemplate: ":") ?? value
        let groups = withoutTimes.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) })
            ? canonicalGroups(in: withoutTimes) : []
        let governmentNumber = governmentNumber(in: groups)
        if matches(Self.identityLabel, in: normalizedLabel)
            || matches(Self.identityWords, in: text)
            || matches(Self.dlLabel, in: normalizedLabel)
            || matches(Self.voterID, in: value)
            || matches(Self.drivingID, in: value)
            || governmentNumber == .verified {
            return .blocked(.governmentID)
        }
        // An unlabeled 4-4-4-4 card also contains 4-4-4 ID-like groups.
        if hasCardNumber(in: groups) { return .blocked(.payment) }
        if governmentNumber == .grouped { return .blocked(.governmentID) }
        if matches(Self.paymentWords, in: text)
            || (matches(Self.upiWords, in: text)
                && matches(Self.upiID, in: value)
                && !matches(Self.authWords, in: normalizedLabel))
            || matches(Self.upiHandle, in: value)
            || matches(Self.upiID, in: value)
            || (matches(Self.expiryLabel, in: normalizedLabel)
                && matches(Self.expiryValue, in: value)) {
            return .blocked(.payment)
        }
        if matches(Self.authWords, in: text)
            || matches(Self.splitOTP, in: normalizedLabel)
            || matches(Self.sentCode, in: value) {
            return .blocked(.authCode)
        }
        return .safe
    }

    private static func matches(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else { return true } // A broken detector must not let data through.
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Split at hard punctuation and separator runs longer than three. Retain
    /// group boundaries and a leading plus for phone-versus-ID disambiguation.
    private struct CanonicalSequence {
        let groups: [String]
        let precededByPlus: Bool
    }

    private static func canonicalGroups(in value: String) -> [CanonicalSequence] {
        var sequences: [CanonicalSequence] = []
        var groups: [String] = []
        var current = ""
        var separatorCount = 0
        var precededByPlus = false
        func flush() {
            if !current.isEmpty { groups.append(current); current = "" }
            if !groups.isEmpty {
                sequences.append(CanonicalSequence(groups: groups, precededByPlus: precededByPlus))
                groups = []
            }
            precededByPlus = false
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
            } else if ":;@".unicodeScalars.contains(scalar) {
                flush() // These punctuation marks delimit times, labels and addresses.
                separatorCount = 0
            } else {
                let category = scalar.properties.generalCategory
                if CharacterSet.whitespacesAndNewlines.contains(scalar)
                    || category == .dashPunctuation || category == .otherPunctuation
                    || category == .connectorPunctuation || category == .spaceSeparator
                    || ",•·−~|".unicodeScalars.contains(scalar)
                    || (scalar == "+" && (!groups.isEmpty || !current.isEmpty)) {
                    separatorCount += 1
                } else {
                    flush()
                    precededByPlus = scalar == "+"
                    separatorCount = 0
                }
            }
        }
        flush()
        return sequences
    }

    private static func hasCardNumber(in sequences: [CanonicalSequence]) -> Bool {
        for sequence in sequences {
            let groups = sequence.groups
            var digits: [Int] = []
            var boundaries = [0]
            var digitGroups: [String] = []
            func check() -> Bool {
                guard digits.count >= 13 else { return false }
                let phones = phoneSpans(digitGroups, precededByPlus: sequence.precededByPlus)
                let years = yearSpans(digitGroups)
                // Only complete groups are candidate numbers: an invalid full card
                // must not be rescued by an accidental valid interior substring.
                for start in boundaries.dropLast() {
                    for end in boundaries.dropFirst() where (13...19).contains(end - start) {
                        if phones.contains(where: { start >= $0.start && start < $0.end })
                            || years.contains(where: { start >= $0.start && start < $0.end }) { continue }
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
                    digitGroups.append(group)
                    boundaries.append(digits.count)
                } else {
                    if check() { return true }
                    digits.removeAll(keepingCapacity: true)
                    digitGroups.removeAll(keepingCapacity: true)
                    boundaries = [0]
                }
            }
            if check() { return true }
        }
        return false
    }

    /// Absolute digit offsets of recognizable phone groups within one numeric run.
    private static func phoneSpans(_ digitGroups: [String], precededByPlus: Bool) -> [(start: Int, end: Int)] {
        let lengths = digitGroups.map(\.count)
        var phoneEnds: [(start: Int, end: Int)] = []
        var offset = 0
        for index in lengths.indices {
            let group = digitGroups[index]
            // Some callers store the country/trunk code in the same digit group.
            let compactPrefix: Int
            if group.count == 11 && group.hasPrefix("0") { compactPrefix = 1 }
            else if group.count == 12 && group.hasPrefix("91") { compactPrefix = 2 }
            else if group.count == 14 && group.hasPrefix("0091") { compactPrefix = 4 }
            else if group.count == 11 && group.hasPrefix("1")
                        && precededByPlus && index == 0 { compactPrefix = 1 }
            else { compactPrefix = 0 }
            if compactPrefix > 0 {
                let mobile = group.dropFirst(compactPrefix)
                if (mobile.first?.wholeNumberValue ?? 0) >= 6
                    || (group.hasPrefix("1") && precededByPlus && index == 0) {
                    phoneEnds.append((offset, offset + group.count))
                }
                offset += group.count
                continue
            }
            let prefix: Int
            if digitGroups[index] == "0091" { prefix = 1 }
            else if digitGroups[index] == "91" { prefix = 1 }
            else if digitGroups[index] == "0" { prefix = 1 }
            else if digitGroups[index] == "1" && precededByPlus && index == 0 { prefix = 2 }
            else { prefix = 0 }
            let mobileIndex = index + (prefix > 0 ? 1 : 0)
            if mobileIndex < lengths.count {
                let mobile = digitGroups[mobileIndex]
                let mobileLength: Int
                if lengths[mobileIndex] == 10 { mobileLength = 10 }
                else if mobileIndex + 1 < lengths.count
                            && lengths[mobileIndex] == 5 && lengths[mobileIndex + 1] == 5 {
                    mobileLength = 10
                } else if prefix == 1 && mobileIndex + 2 < lengths.count
                            && Array(lengths[mobileIndex...(mobileIndex + 2)]) == [2, 4, 4] {
                    mobileLength = 10 // +91 landline
                } else if prefix == 2 && mobileIndex + 2 < lengths.count
                            && Array(lengths[mobileIndex...(mobileIndex + 2)]) == [3, 3, 4] {
                    mobileLength = 10 // +1 North American number
                } else { mobileLength = 0 }
                if mobileLength == 10 && ((mobile.first?.wholeNumberValue ?? 0) >= 6
                                  || (prefix == 1 && lengths[mobileIndex] == 2)
                                  || prefix == 2) {
                    phoneEnds.append((offset, offset + (prefix > 0 ? lengths[index] : 0) + 10))
                }
            }
            offset += lengths[index]
        }
        return phoneEnds
    }

    /// Plausible calendar-year groups are not ID/card digits unless labelled as such.
    private static func yearSpans(_ groups: [String]) -> [(start: Int, end: Int)] {
        var spans: [(start: Int, end: Int)] = []
        var offset = 0
        var runStart = 0
        var runCount = 0
        for group in groups {
            if group.count == 4 && (1900...2099).contains(Int(group) ?? 0) {
                if runCount == 0 { runStart = offset }
                runCount += 1
            } else {
                if runCount >= 3 { spans.append((runStart, offset)) }
                runCount = 0
            }
            offset += group.count
        }
        if runCount >= 3 { spans.append((runStart, offset)) }
        return spans
    }

    private enum GovernmentNumber {
        case none, verified, grouped
    }

    private static func governmentNumber(in sequences: [CanonicalSequence]) -> GovernmentNumber {
        var foundGroupedID = false
        for sequence in sequences {
            let groups = sequence.groups
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
                        && chars[9].isASCII && chars[9].isLetter { return .verified }
                }
            }
            var digitGroups: [String] = []
            func check() -> Bool {
                let digits = digitGroups.joined().compactMap(\.wholeNumberValue)
                let lengths = digitGroups.map(\.count)
                if digits.count == 9 && lengths.count == 1 { return true }
                if lengths.count >= 3 {
                    for index in 0..<(lengths.count - 2) {
                        if Array(lengths[index...(index + 2)]) == [3, 2, 4] { return true }
                        if Array(lengths[index...(index + 2)]) == [4, 4, 4] {
                            let years = digitGroups[index...(index + 2)].allSatisfy {
                                (1900...2099).contains(Int($0) ?? 0)
                            }
                            if !years { foundGroupedID = true }
                        }
                    }
                }
                guard digits.count >= 12 else { return false }
                // Exempt only windows starting inside an actual phone, never a later ID.
                // Prefixes are included in the span, including the 11-digit +1 phone.
                let phoneEnds = phoneSpans(digitGroups, precededByPlus: sequence.precededByPlus)
                let years = yearSpans(digitGroups)
                for start in 0...(digits.count - 12) where (2...9).contains(digits[start]) {
                    if phoneEnds.contains(where: { start >= $0.start && start < $0.end })
                        || years.contains(where: { start >= $0.start && start < $0.end }) { continue }
                    if isVerhoeffValid(digits[start..<(start + 12)]) { return true }
                }
                return false
            }
            for group in groups {
                if group.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    digitGroups.append(group)
                } else {
                    if check() { return .verified }
                    digitGroups.removeAll(keepingCapacity: true)
                }
            }
            if check() { return .verified }
        }
        return foundGroupedID ? .grouped : .none
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
