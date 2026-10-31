import Foundation
import PikoKit

/// Read access to the user's calendar, for clash checks before adding anything.
public protocol CalendarContext: Sendable {
    /// Titles of events overlapping `start..<end`.
    func busy(from start: Date, to end: Date) async -> [String]
}

/// The lightweight orchestrator. A deterministic, instant state machine that turns a plan into
/// a short spoken back-and-forth: ask for a missing time, raise calendar clashes, confirm, run.
/// The model is only used to plan new requests; follow-up answers never wait on it.
public struct Conversation: Sendable {
    public enum Reply: Equatable, Sendable {
        /// A question; keep listening for the answer.
        case ask(String)
        /// Read-back of the plan; keep listening for yes / no / a change.
        case confirm(String)
        /// Say this, then run `plan`.
        case run(String)
        case cancelled(String)
    }

    public enum Waiting: Equatable, Sendable {
        case none, confirm, time(Int), clash(Int)
    }

    /// Tools that change something outside Piko and so are read back before running.
    public static let confirmable: Set<String> = [
        ToolName.reminder, ToolName.calendar, ToolName.shortcut, ToolName.remember, ToolName.forget,
    ]

    public private(set) var plan: [ToolCall] = []
    public private(set) var waiting: Waiting = .none
    /// Only the exact plan read back and explicitly accepted by the user may authorize writes.
    public private(set) var confirmedPlan: [ToolCall] = []
    private var descriptorRisks: [String: ToolRisk]?
    private var requiresExplicitConfirmation = false
    private var acceptedClashes: Set<UUID> = []
    private var retried = false

    public var isWaiting: Bool { waiting != .none }

    public init() {}

    public mutating func begin(_ plan: [ToolCall], context: (any CalendarContext)?, now: Date,
                               descriptors: [ToolDescriptor]? = nil,
                               requiresExplicitConfirmation: Bool = false) async -> Reply {
        self.plan = plan
        self.requiresExplicitConfirmation = requiresExplicitConfirmation
        confirmedPlan = []
        descriptorRisks = descriptors.map { descriptors in
            Dictionary(descriptors.map { ($0.name, $0.risk) }, uniquingKeysWith: { first, _ in first })
        }
        acceptedClashes = []
        retried = false
        return await review(context: context, now: now)
    }

    /// A matching ID alone is insufficient: the title, date, origin and fact revision must match.
    public func isConfirmed(_ call: ToolCall) -> Bool {
        requiresConfirmation(call) && plan.contains(call) && confirmedPlan.contains(call)
    }

    public func requiresConfirmation(_ call: ToolCall) -> Bool {
        if requiresExplicitConfirmation || call.tool == ToolName.remember || call.tool == ToolName.forget { return true }
        guard let descriptorRisks else { return Self.confirmable.contains(call.tool) }
        // Unknown tools are never an automatic local fast path.
        return descriptorRisks[call.tool] != .local && descriptorRisks[call.tool] != .read
    }

    /// Handles a follow-up. Returns nil when the speech is not an answer — treat it as a new request.
    public mutating func hear(_ text: String, context: (any CalendarContext)?, now: Date) async -> Reply? {
        let answer = Answer(text)
        switch waiting {
        case .none:
            return nil
        case .time(let index):
            if let time = answer.time {
                setTime(time, on: index, now: now)
            } else if answer.isNo {
                plan.remove(at: index)
            } else {
                return retryOrCancel("Sorry, what time should I use?")
            }
        case .clash(let index):
            if let time = answer.time {
                setTime(time, on: index, now: now)
            } else if answer.isYes {
                acceptedClashes.insert(plan[index].id)
            } else if answer.isNo {
                plan.remove(at: index)
            } else {
                return retryOrCancel("Should I still add it, or pick another time?")
            }
        case .confirm:
            let timed = plan.indices.filter { plan[$0].when != nil }
            if let time = answer.time, timed.count == 1 {
                setTime(time, on: timed[0], now: now)
            } else if answer.isYes {
                waiting = .none
                confirmedPlan = plan
                return .run("On it.")
            } else if answer.isNo {
                return cancel()
            } else {
                waiting = .none
                return nil
            }
        }
        retried = false
        return await review(context: context, now: now)
    }

    // MARK: - Review

    private mutating func review(context: (any CalendarContext)?, now: Date) async -> Reply {
        confirmedPlan = []
        guard !plan.isEmpty else { return cancel() }
        for (index, step) in plan.enumerated() where step.tool == ToolName.calendar {
            guard let when = step.when, step.timeKnown else {
                waiting = .time(index)
                let day = step.when.map { " " + Self.dayPhrase($0, now: now) } ?? ""
                return .ask("What time should I put \(step.text)\(day) on your calendar?")
            }
            if !acceptedClashes.contains(step.id),
               let clash = await context?.busy(from: when, to: when.addingTimeInterval(3_600)).first {
                waiting = .clash(index)
                return .ask("You already have \(clash) \(Self.datePhrase(when, timeKnown: true, now: now)). "
                            + "Should I still add \(step.text), or pick another time?")
            }
        }
        guard plan.contains(where: requiresConfirmation) else {
            waiting = .none
            return .run("Saved.")
        }
        waiting = .confirm
        return .confirm("I'll \(Self.summary(plan, now: now)). Shall I go ahead?")
    }

    private mutating func setTime(_ time: (hour: Int, minute: Int), on index: Int, now: Date) {
        confirmedPlan = []
        let calendar = Calendar.current
        let day = plan[index].when ?? calendar.startOfDay(for: now)
        guard var date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) else { return }
        if plan[index].when == nil, date <= now, let next = calendar.date(byAdding: .day, value: 1, to: date) {
            date = next
        }
        plan[index].when = date
        plan[index].timeKnown = true
        acceptedClashes.remove(plan[index].id)
    }

    private mutating func retryOrCancel(_ question: String) -> Reply {
        guard !retried else { return cancel() }
        retried = true
        return .ask(question)
    }

    private mutating func cancel() -> Reply {
        waiting = .none
        plan = []
        confirmedPlan = []
        return .cancelled("Okay, I won't do that.")
    }

    // MARK: - Speech

    static func summary(_ plan: [ToolCall], now: Date) -> String {
        let parts = plan.map { step -> String in
            let when = step.when.map { " " + datePhrase($0, timeKnown: step.timeKnown, now: now) } ?? ""
            switch step.tool {
            case ToolName.reminder: return "remind you to \(lowerFirst(step.text))\(when)"
            case ToolName.calendar: return "add \(step.text) to your calendar\(when)"
            case ToolName.checkIn: return "check in with you\(when)"
            case ToolName.shortcut: return "run your \(step.text) shortcut"
            case ToolName.journal: return "save a journal entry"
            case ToolName.remember:
                if case .remember(_, let subject, let value)? = PersonalIntent.parse(step.text) {
                    return "remember that your \(subject) is \(value)"
                }
                return "save a personal fact"
            case ToolName.forget:
                if case .forget(_, let subject)? = PersonalIntent.parse(step.text) {
                    return "forget what I saved about your \(subject)"
                }
                return "forget a personal fact"
            case ToolName.note: return "save a note"
            default: return "\(step.tool): \(step.text)"
            }
        }
        return ListFormatter.localizedString(byJoining: parts)
    }

    static func datePhrase(_ date: Date, timeKnown: Bool, now: Date) -> String {
        let day = dayPhrase(date, now: now)
        guard timeKnown else { return day }
        return "\(day) at \(date.formatted(date: .omitted, time: .shortened))"
    }

    static func dayPhrase(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        if days == 1 { return "tomorrow" }
        if (2...6).contains(days) { return "on " + date.formatted(.dateTime.weekday(.wide)) }
        return "on " + date.formatted(.dateTime.day().month(.abbreviated))
    }

    private static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

/// Instant, rule-based reading of a spoken follow-up.
struct Answer {
    let isYes: Bool
    let isNo: Bool
    let time: (hour: Int, minute: Int)?

    private static let yesWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "alright", "please", "haan", "ha", "correct",
        "right", "fine", "anyway", "still", "perfect", "great",
    ]
    private static let yesPhrases = ["go ahead", "do it", "sounds good", "add it", "keep it", "that works", "of course"]
    private static let noWords: Set<String> = [
        "no", "nope", "nah", "nothing", "cancel", "don't", "dont", "stop", "nahi", "skip",
    ]
    private static let noPhrases = ["never mind", "nevermind", "leave it", "forget it", "not now"]

    init(_ text: String) {
        let lowered = text.lowercased()
        let words = Set(lowered.components(separatedBy: CharacterSet.letters.union(.init(charactersIn: "'")).inverted))
        let saidNo = !words.isDisjoint(with: Self.noWords) || Self.noPhrases.contains(where: lowered.contains)
        let saidYes = !words.isDisjoint(with: Self.yesWords) || Self.yesPhrases.contains(where: lowered.contains)
        time = SpokenDate.spokenTime(in: text) ?? Self.bareTime(lowered)
        isNo = saidNo && time == nil
        isYes = saidYes && !saidNo
    }

    /// "make it 5", "five thirty", "4" — a short answer to "what time?".
    private static func bareTime(_ lowered: String) -> (hour: Int, minute: Int)? {
        let words = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let numbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                       "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
        guard words.count <= 5,
              let index = words.firstIndex(where: { (Int($0).map { (1...12).contains($0) } ?? false) || numbers[$0] != nil }),
              let hour = Int(words[index]) ?? numbers[words[index]] else { return nil }
        var minute = 0
        if index + 1 < words.count {
            if words[index + 1] == "thirty" { minute = 30 }
            if words[index + 1] == "fifteen" { minute = 15 }
            if words[index + 1] == "forty", index + 2 < words.count, words[index + 2] == "five" { minute = 45 }
        }
        return ((1...7).contains(hour) ? hour + 12 : hour, minute)
    }
}
