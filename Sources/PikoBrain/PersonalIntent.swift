import Foundation
import PikoKit

/// Only explicit, narrowly worded requests enter personal memory. Never extract facts from history.
public enum PersonalIntent: Equatable, Sendable {
    case remember(key: String, subject: String, value: String)
    case forget(key: String, subject: String)
    case ask(key: String, subject: String)

    public var key: String {
        switch self {
        case .remember(let key, _, _), .forget(let key, _), .ask(let key, _): key
        }
    }

    public var subject: String {
        switch self {
        case .remember(_, let subject, _), .forget(_, let subject), .ask(_, let subject): subject
        }
    }

    public static func parse(_ utterance: String) -> Self? {
        guard utterance.utf8.count <= 512, !utterance.contains("\0") else { return nil }
        let edge = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?"))
        var text = utterance.trimmingCharacters(in: edge)
        guard !text.isEmpty else { return nil }
        if let rest = dropPrefix("piko", from: text),
           let first = rest.first, first.isWhitespace || first == "," || first == ":" {
            text = rest.trimmingCharacters(in: edge.union(CharacterSet(charactersIn: ":")))
        }
        if let rest = dropPrefix("remember ", from: text) {
            let body = dropPrefix("that ", from: rest) ?? rest
            guard let my = dropPrefix("my ", from: body),
                  let separator = my.range(of: " is ", options: .caseInsensitive),
                  let subject = normalizedSubject(String(my[..<separator.lowerBound])) else { return nil }
            let value = my[separator.upperBound...].trimmingCharacters(in: edge)
            let loweredValue = value.lowercased()
            guard !value.isEmpty, value.utf8.count <= 256,
                  !value.contains(where: \.isNewline),
                  ![" and remind me", " then remind me", " and schedule", " and add to",
                    " and make a note", " and my "].contains(where: loweredValue.contains) else { return nil }
            return .remember(key: subject.key, subject: subject.label, value: value)
        }
        if let rest = dropPrefix("forget my ", from: text),
           let subject = normalizedSubject(rest) {
            return .forget(key: subject.key, subject: subject.label)
        }
        for lead in ["who is my ", "who's my ", "who’s my ",
                     "what is my ", "what's my ", "what’s my "] {
            if let rest = dropPrefix(lead, from: text),
               let subject = normalizedSubject(rest) {
                return .ask(key: subject.key, subject: subject.label)
            }
        }
        return nil
    }

    private static func dropPrefix(_ prefix: String, from text: String) -> String? {
        guard let range = text.range(of: prefix, options: [.anchored, .caseInsensitive]) else { return nil }
        return String(text[range.upperBound...])
    }

    private static func normalizedSubject(_ raw: String) -> (key: String, label: String)? {
        let words = raw.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let excluded: Set<String> = [
            "calendar", "calendars", "schedule", "schedules", "reminder", "reminders",
            "note", "notes", "journal", "journals",
        ]
        guard (1...6).contains(words.count), words.joined(separator: " ").utf8.count <= 80,
              words.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy {
                  CharacterSet.alphanumerics.contains($0)
              } && !excluded.contains($0) }) else { return nil }
        return ("my/" + words.joined(separator: "-"), words.joined(separator: " "))
    }
}

public enum PersonalAnswer {
    /// A personal question has exactly one evidence source: a saved fact. History is not a fallback.
    public static func reply(subject: String, fact: MemoryFact?) -> String {
        guard let fact else { return "I don't know your \(subject) yet." }
        let ending = fact.value.last.map { ".!?".contains($0) } == true ? "" : "."
        return "Your \(subject) is \(fact.value)\(ending)"
    }
}
