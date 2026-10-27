import Foundation
import PikoKit

/// Free baseline organizer for every iPhone: deterministic cue phrases plus Foundation's
/// `NSDataDetector` for spoken dates. Never invents content; it only splits and labels.
public struct RuleOrganizer: Organizer {
    public init() {}

    /// Leading phrases stripped from a reminder's title.
    static let reminderLeads = [
        "remind me to ", "remind me ", "don't forget to ", "do not forget to ",
        "i need to ", "i have to ", "i've got to ", "need to ",
    ]
    /// Phrases that start a reminder but stay part of its title.
    static let reminderKeeps = ["buy ", "call ", "pick up ", "book ", "pay ", "email ", "text ", "order "]
    static let journalCues = [
        "i feel", "i felt", "i'm feeling", "i am feeling", "i was feeling", "today was", "today i", "i'm so", "i am so",
    ]

    public func organize(_ text: String, now: Date) async throws -> [DumpItem] {
        Self.clauses(in: text).map { Self.item(for: $0, now: now) }
    }

    public func answer(_ question: String, from history: [CaptureResult]) async throws -> String {
        let keywords = RecallQuery.keywords(from: question)
        let matches = history.filter { result in
            let lowered = result.shipped.lowercased()
            return keywords.contains { lowered.contains($0) }
        }
        guard !matches.isEmpty else { return "I couldn't find anything you said about that yet." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return matches.prefix(3)
            .map { "On \(formatter.string(from: $0.createdAt)) you said: \($0.shipped)" }
            .joined(separator: "\n")
    }

    // MARK: - Splitting

    static func startsWithCue(_ lowered: String) -> Bool {
        (reminderLeads + reminderKeeps + journalCues).contains { lowered.hasPrefix($0) }
    }

    static func clauses(in text: String) -> [String] {
        var clauses: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            var current = ""
            for fragment in sentence.split(separator: ",", omittingEmptySubsequences: true) {
                var piece = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
                if piece.lowercased().hasPrefix("and ") { piece = String(piece.dropFirst(4)) }
                if !current.isEmpty, startsWithCue(piece.lowercased()) {
                    clauses.append(current)
                    current = piece
                } else {
                    let raw = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
                    current = current.isEmpty ? piece : current + ", " + raw
                }
            }
            if !current.isEmpty { clauses.append(current) }
        }
        return clauses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".!?"))) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Labelling

    static func item(for clause: String, now: Date) -> DumpItem {
        let lowered = clause.lowercased()
        if let lead = reminderLeads.first(where: lowered.hasPrefix) {
            return reminder(String(clause.dropFirst(lead.count)), now: now)
        }
        if reminderKeeps.contains(where: lowered.hasPrefix) {
            return reminder(clause, now: now)
        }
        let kind: DumpItem.Kind = journalCues.contains(where: lowered.hasPrefix) ? .journal : .note
        return DumpItem(kind: kind, text: sentence(clause), createdAt: now)
    }

    static func reminder(_ title: String, now: Date) -> DumpItem {
        let (cleaned, due) = SpokenDate.removing(from: title, now: now)
        return DumpItem(kind: .reminder, text: capitalized(cleaned.trimmingCharacters(in: .whitespaces)),
                        due: due?.date, dueHasTime: due?.hasTime ?? true, createdAt: now)
    }

    /// `NSDataDetector` resolves relative phrases against the real clock; rebase onto `now`.
    static func resolve(_ match: NSTextCheckingResult, now: Date) -> Date? {
        guard let detected = match.date else { return nil }
        let offset = detected.timeIntervalSinceNow
        let calendar = Calendar.current
        let dayShift = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now),
                                               to: calendar.startOfDay(for: detected)).day ?? 0
        let time = calendar.dateComponents([.hour, .minute], from: detected)
        guard let day = calendar.date(byAdding: .day, value: dayShift, to: calendar.startOfDay(for: now)),
              let rebased = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0,
                                          second: 0, of: day) else {
            return now.addingTimeInterval(offset)
        }
        return rebased
    }

    static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    static func sentence(_ text: String) -> String {
        let capped = capitalized(text)
        guard let last = capped.last, !".!?".contains(last) else { return capped }
        return capped + "."
    }
}

/// Keywords for searching the user's own history from a spoken question.
public enum RecallQuery {
    static let stopwords: Set<String> = [
        "what", "did", "i", "say", "said", "about", "the", "a", "an", "when", "where", "who", "how",
        "do", "does", "my", "me", "was", "were", "is", "are", "with", "to", "of", "and", "or", "for",
        "on", "in", "at", "tell", "remind", "show", "find", "search", "anything", "ever", "that",
        "this", "it", "you", "can", "could", "please", "piko", "mention", "mentioned", "talk", "talked",
    ]

    public static func keywords(from question: String) -> [String] {
        question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopwords.contains($0) }
    }
}
