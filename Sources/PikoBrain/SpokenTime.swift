import Foundation

/// A spoken date or time, resolved. `hasTime` is false when only a day was said ("Friday"),
/// so callers ask for a time instead of silently picking noon.
public struct SpokenWhen: Equatable, Sendable {
    public var date: Date
    public var hasTime: Bool

    public init(date: Date, hasTime: Bool) {
        self.date = date
        self.hasTime = hasTime
    }
}

/// Spoken dates and times. `NSDataDetector` finds days; times are parsed here because the
/// detector turns a bare "Friday" into noon, drops "at four", reads "4 o'clock" as 4 AM and
/// keeps a time that has already passed today.
public enum SpokenDate {
    private struct TimeMention {
        var hour: Int
        var minute: Int
        var range: Range<String.Index>
    }

    private static let numberWords = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]
    private static let number = #"(\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"#
    private static let meridiem = try! NSRegularExpression(
        pattern: #"\b"# + number + #"(?::([0-5]\d))?\s*([ap])\.?\s?m\b\.?"#, options: .caseInsensitive)
    private static let clock = try! NSRegularExpression(
        pattern: #"\b([01]?\d|2[0-3]):([0-5]\d)\b(?!\s*[ap]\.?\s?m)"#, options: .caseInsensitive)
    private static let atHour = try! NSRegularExpression(
        pattern: #"\bat\s+"# + number + #"\b(?![:\d])(?!\s*(?:[ap]\.?\s?m|days?|weeks?|months?|minutes?|mins?|hours?|items?|people|times|percent))"#,
        options: .caseInsensitive)
    private static let oClock = try! NSRegularExpression(
        pattern: #"\b"# + number + #"\s*o'?\s?clock\b"#, options: .caseInsensitive)
    private static let corrected = try! NSRegularExpression(
        pattern: #"\b(?:i mean|actually|make it|sorry|no)[,\s]+(?:at\s+)?"# + number
            + #"\b(?![:\d])(?!\s*(?:[ap]\.?\s?m|days?|weeks?|minutes?|mins?|hours?|items?|people|times))"#,
        options: .caseInsensitive)
    private static let named = try! NSRegularExpression(
        pattern: #"\b(noon|midday|midnight)\b"#, options: .caseInsensitive)
    private static let partOfDay = try! NSRegularExpression(
        pattern: #"\b(morning|afternoon|evening|tonight|night)\b"#, options: .caseInsensitive)
    private static let dayWords = try! NSRegularExpression(
        pattern: #"\b(today|tonight|tomorrow|day after|next (?:week|month)|(?:mon|tues?|wed(?:nes)?|thu(?:rs)?|fri|sat(?:ur)?|sun)(?:day)?|jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december|\d{1,2}(?:st|nd|rd|th))\b"#,
        options: .caseInsensitive)

    /// Resolves `phrase`. When the phrase names only a day, a time spoken right after it in
    /// `context` is used ("on Friday at four").
    public static func resolve(_ phrase: String, context: String, now: Date) -> SpokenWhen? {
        let calendar = Calendar.current
        let day = spokenDay(in: phrase, now: now)
        var time = times(in: phrase).last.map { ($0.hour, $0.minute) } ?? partOfDayTime(in: phrase)
        if time == nil, day != nil {
            time = timeNear(phrase, in: context)
        }
        guard let (hour, minute) = time else {
            return day.flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
                .map { SpokenWhen(date: $0, hasTime: false) }
        }
        let base = day ?? calendar.startOfDay(for: now)
        guard var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) else { return nil }
        if day == nil, date <= now, let next = calendar.date(byAdding: .day, value: 1, to: date) {
            date = next
        }
        return SpokenWhen(date: date, hasTime: true)
    }

    public static func parse(_ phrase: String, now: Date) -> Date? {
        resolve(phrase, context: "", now: now)?.date
    }

    /// Removes every spoken date/time (and a preposition just before it) from a title.
    static func removing(from text: String, now: Date) -> (text: String, when: SpokenWhen?) {
        let when = resolve(text, context: text, now: now)
        guard when != nil else { return (text, nil) }
        var ranges = times(in: text).map(\.range)
        ranges += matches(partOfDay, in: text) + matches(dayWords, in: text)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            ranges += detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text) }
        }
        var output = text
        for range in merged(ranges, in: text).reversed() {
            var lower = range.lowerBound
            let before = output[..<lower].lowercased()
            for preposition in [" at ", " on ", " by ", " for ", " this ", " next "] where before.hasSuffix(preposition) {
                lower = output.index(lower, offsetBy: -(preposition.count - 1))
                break
            }
            output.removeSubrange(lower..<range.upperBound)
        }
        output = output.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        for dangling in [" at", " on", " by", " for", ","] where output.lowercased().hasSuffix(dangling) {
            output = String(output.dropLast(dangling.count))
        }
        return (output.trimmingCharacters(in: .whitespaces), when)
    }

    /// Times and times only — for follow-up answers like "make it 5" or "at four thirty".
    public static func spokenTime(in text: String) -> (hour: Int, minute: Int)? {
        times(in: text).last.map { ($0.hour, $0.minute) } ?? partOfDayTime(in: text)
    }

    // MARK: - Parsing

    private static func times(in text: String) -> [TimeMention] {
        var found: [TimeMention] = []
        let ns = NSRange(text.startIndex..., in: text)
        for match in meridiem.matches(in: text, range: ns) {
            guard let range = Range(match.range, in: text), var hour = value(match, 1, text) else { continue }
            let minute = value(match, 2, text) ?? 0
            let pm = substring(match, 3, text)?.lowercased() == "p"
            hour = hour % 12 + (pm ? 12 : 0)
            found.append(TimeMention(hour: hour, minute: minute, range: range))
        }
        for match in clock.matches(in: text, range: ns) {
            guard let range = Range(match.range, in: text), let hour = value(match, 1, text),
                  let minute = value(match, 2, text) else { continue }
            found.append(TimeMention(hour: daytime(hour), minute: minute, range: range))
        }
        for regex in [atHour, oClock, corrected] {
            for match in regex.matches(in: text, range: ns) {
                guard let range = Range(match.range, in: text), let hour = value(match, 1, text),
                      (1...12).contains(hour) else { continue }
                found.append(TimeMention(hour: daytime(hour), minute: 0, range: range))
            }
        }
        for match in named.matches(in: text, range: ns) {
            guard let range = Range(match.range, in: text) else { continue }
            let hour = substring(match, 1, text)?.lowercased() == "midnight" ? 0 : 12
            found.append(TimeMention(hour: hour, minute: 0, range: range))
        }
        // The latest-ending, then longest, mention wins: "at 3, no actually 5 pm" means 5 PM.
        return found.sorted {
            $0.range.upperBound != $1.range.upperBound
                ? $0.range.upperBound < $1.range.upperBound
                : $0.range.lowerBound > $1.range.lowerBound
        }
    }

    /// Hours 1–7 without AM/PM are almost always afternoon or evening plans.
    private static func daytime(_ hour: Int) -> Int {
        (1...7).contains(hour) ? hour + 12 : hour
    }

    private static func partOfDayTime(in text: String) -> (Int, Int)? {
        guard let match = partOfDay.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let word = substring(match, 1, text)?.lowercased() else { return nil }
        switch word {
        case "morning": return (9, 0)
        case "afternoon": return (15, 0)
        case "evening": return (18, 0)
        default: return (20, 0)
        }
    }

    private static func spokenDay(in text: String, now: Date) -> Date? {
        let lowered = text.lowercased()
        guard !matches(dayWords, in: text).isEmpty else { return nil }
        if lowered.contains("tonight") || lowered.contains("today") {
            return Calendar.current.startOfDay(for: now)
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let found = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { match in
            guard let range = Range(match.range, in: text) else { return false }
            return !matches(dayWords, in: String(text[range])).isEmpty
        }
        guard let match = found.last, let date = RuleOrganizer.resolve(match, now: now) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    private static func timeNear(_ phrase: String, in context: String) -> (Int, Int)? {
        guard !phrase.isEmpty, let found = context.range(of: phrase, options: .caseInsensitive) else { return nil }
        let end = context.index(found.upperBound, offsetBy: 30, limitedBy: context.endIndex) ?? context.endIndex
        let window = String(context[found.upperBound..<end])
        let start = context.index(found.lowerBound, offsetBy: -20, limitedBy: context.startIndex) ?? context.startIndex
        let before = String(context[start..<found.lowerBound])
        return times(in: window).first.map { ($0.hour, $0.minute) }
            ?? times(in: before).last.map { ($0.hour, $0.minute) }
    }

    // MARK: - Regex helpers

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [Range<String.Index>] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    private static func substring(_ match: NSTextCheckingResult, _ group: Int, _ text: String) -> String? {
        guard match.range(at: group).location != NSNotFound,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func value(_ match: NSTextCheckingResult, _ group: Int, _ text: String) -> Int? {
        guard let raw = substring(match, group, text)?.lowercased() else { return nil }
        return Int(raw) ?? numberWords[raw]
    }

    private static func merged(_ ranges: [Range<String.Index>], in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
