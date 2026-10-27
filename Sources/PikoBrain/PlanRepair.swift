import Foundation
import PikoKit

/// Fast, deterministic checks that run after the model proposes a plan. The model decides
/// what was asked; these rules decide which part of the sentence each step owns, so a step
/// never borrows another step's time, feelings are never dropped, and filler does nothing.
enum PlanRepair {
    static let timedTools: Set<String> = [ToolName.reminder, ToolName.calendar, ToolName.checkIn]

    private static let fillers: Set<String> = [
        "hmm", "hm", "um", "umm", "uh", "uhh", "er", "ah", "oh", "okay", "ok", "so", "yeah", "yes", "like",
        "well", "cancel", "nothing", "never", "mind", "basically", "anyway", "right", "alright",
    ]
    private static let leadingJoins = ["and also ", "and then ", "and ", "also ", "but ", "so ", "then ", "plus "]
    private static let corrections = ["no actually", "no,", "no ", "sorry", "i mean", "actually", "wait"]
    private static let ideaCues = ["idea", "app idea", "an idea", "random thought", "thought", "what if"]

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    static func isFillerOnly(_ text: String) -> Bool {
        words(text).allSatisfy(fillers.contains)
    }

    static func isIdea(_ clause: String) -> Bool {
        let lowered = clause.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ideaCues.contains { lowered.hasPrefix($0) }
    }

    /// Clauses in speaking order. Self-corrections ("no actually 5 pm", "sorry, I mean 3") stay
    /// with the clause they correct; short labels ("app idea") stay with what follows.
    static func clauses(_ request: String) -> [String] {
        let separators = CharacterSet(charactersIn: ".!?;,")
        var pieces: [String] = []
        for part in request.components(separatedBy: separators) {
            for piece in part.components(separatedBy: " and ") {
                var trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                for join in leadingJoins where trimmed.lowercased().hasPrefix(join) {
                    trimmed = String(trimmed.dropFirst(join.count))
                    break
                }
                if !trimmed.isEmpty { pieces.append(trimmed) }
            }
        }
        var merged: [String] = []
        var pendingLabel: String?
        for piece in pieces {
            let lowered = piece.lowercased()
            if let last = merged.last, corrections.contains(where: { lowered.hasPrefix($0) }) || isBareNumber(lowered) {
                merged[merged.count - 1] = last + ", " + piece
                continue
            }
            if words(piece).count <= 2, !isFillerOnly(piece), isIdea(piece) {
                pendingLabel = piece
                continue
            }
            if let label = pendingLabel {
                merged.append(label + ", " + piece)
                pendingLabel = nil
            } else {
                merged.append(piece)
            }
        }
        if let label = pendingLabel { merged.append(label) }
        return merged
    }

    private static func isBareNumber(_ lowered: String) -> Bool {
        let parts = words(lowered)
        return parts.count == 1 && (Int(parts[0]) != nil)
    }

    /// The clause a step came from: the one sharing the most meaningful words with its text.
    static func clauseIndex(for text: String, in clauses: [String]) -> Int? {
        let wanted = Set(words(text).filter { $0.count > 2 })
        guard !wanted.isEmpty else { return nil }
        let scored = clauses.enumerated().map { ($0.offset, Set(words($0.element)).intersection(wanted).count) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    /// Feelings the model left out, kept as journal entries. Never adds actions. A following
    /// clause that the model filed only as a note is absorbed into the same entry.
    static func missedJournal(clauses: [String], covered: Set<Int>, noteOnly: Set<Int>, now: Date)
        -> [(position: Int, text: String, absorbed: [Int])] {
        var found: [(Int, String, [Int])] = []
        var index = 0
        while index < clauses.count {
            defer { index += 1 }
            guard !covered.contains(index), !isFillerOnly(clauses[index]),
                  RuleOrganizer.item(for: clauses[index], now: now).kind == .journal else { continue }
            var parts = [clauses[index]]
            var absorbed: [Int] = []
            var next = index + 1
            while next < clauses.count, !covered.contains(next) || noteOnly.contains(next),
                  !isFillerOnly(clauses[next]), !isIdea(clauses[next]),
                  RuleOrganizer.item(for: clauses[next], now: now).kind != .reminder {
                parts.append(clauses[next])
                if covered.contains(next) { absorbed.append(next) }
                next += 1
            }
            found.append((index, RuleOrganizer.sentence(parts.joined(separator: ", ")), absorbed))
            index = next - 1
        }
        return found
    }
}
