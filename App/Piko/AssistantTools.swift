import EventKit
import Foundation
import PikoBrain
import PikoKit
import UIKit
import UserNotifications

/// The tools Piko's planner may use. Each one only touches public iOS APIs; anything that
/// changes another app is `.external`, so `ToolHarness` runs it only after the user approves.
enum AssistantTools {
    @MainActor
    static func all(memory: any Memory, items: any ItemStore, reminders: ReminderWriter) -> [any PikoTool] {
        [
            ReminderTool(writer: reminders),
            CalendarTool(),
            SaveTool(name: ToolName.note, kind: .note, items: items),
            SaveTool(name: ToolName.journal, kind: .journal, items: items),
            CheckInTool(),
            ShortcutTool(),
            SearchTool(memory: memory),
            PersonalWriteTool(name: ToolName.remember, memory: memory),
            PersonalWriteTool(name: ToolName.forget, memory: memory),
        ]
    }

    static func symbol(for tool: String) -> String {
        switch tool {
        case ToolName.reminder: "checklist"
        case ToolName.calendar: "calendar"
        case ToolName.journal: "heart.text.square"
        case ToolName.checkIn: "bell.badge"
        case ToolName.shortcut: "square.stack.3d.up"
        case ToolName.search: "magnifyingglass"
        case ToolName.remember: "brain.head.profile"
        case ToolName.forget: "trash"
        default: "note.text"
        }
    }
}

private struct ReminderTool: PikoTool {
    let writer: ReminderWriter
    let descriptor = ToolDescriptor(name: ToolName.reminder, summary: "Add a to-do to Apple Reminders", risk: .external)

    func run(_ call: ToolCall) async throws -> String {
        try await writer.add([DumpItem(kind: .reminder, text: call.text, due: call.when)])
        return "Reminder added: \(call.text)"
    }
}

private struct CalendarTool: PikoTool {
    let descriptor = ToolDescriptor(name: ToolName.calendar, summary: "Add an event at a time to the calendar", risk: .external)

    func run(_ call: ToolCall) async throws -> String {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { throw ReminderWriter.Failure.accessDenied }
        let start = call.when ?? Calendar.current.nextDate(
            after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
        let event = EKEvent(eventStore: store)
        event.title = call.text
        event.startDate = start
        event.endDate = start.addingTimeInterval(3_600)
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        return "Added to calendar: \(call.text)"
    }
}

private struct SaveTool: PikoTool {
    let name: String
    let kind: DumpItem.Kind
    let items: any ItemStore
    var descriptor: ToolDescriptor {
        ToolDescriptor(name: name,
                       summary: kind == .journal ? "Save a feeling or reflection to the private journal"
                                                 : "Save an idea or fact as a private note",
                       risk: .local)
    }

    func run(_ call: ToolCall) async throws -> String {
        await items.save([DumpItem(kind: kind, text: call.text)])
        return kind == .journal ? "Journal entry saved" : "Note saved"
    }
}

private struct CheckInTool: PikoTool {
    let descriptor = ToolDescriptor(name: ToolName.checkIn, summary: "Schedule a gentle nudge from Piko at a time", risk: .local)

    func run(_ call: ToolCall) async throws -> String {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw ReminderWriter.Failure.accessDenied
        }
        let calendar = Calendar.current
        let fireDate = call.when ?? calendar.nextDate(
            after: .now, matching: DateComponents(hour: 21, minute: 0), matchingPolicy: .nextTime) ?? .now
        let content = UNMutableNotificationContent()
        content.title = "Piko"
        content.body = call.text
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
            repeats: false)
        try await center.add(UNNotificationRequest(identifier: call.id.uuidString, content: content, trigger: trigger))
        return "Piko will check in \(fireDate.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct ShortcutTool: PikoTool {
    let descriptor = ToolDescriptor(name: ToolName.shortcut, summary: "Run one of the user's Shortcuts by its name", risk: .external)

    func run(_ call: ToolCall) async throws -> String {
        var components = URLComponents(string: "shortcuts://run-shortcut")
        components?.queryItems = [URLQueryItem(name: "name", value: call.text)]
        guard let url = components?.url, await Self.open(url) else {
            throw PikoError.brainUnavailable("shortcut")
        }
        return "Running shortcut: \(call.text)"
    }

    @MainActor private static func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
}

private struct SearchTool: PikoTool {
    let memory: any Memory
    let descriptor = ToolDescriptor(name: ToolName.search, summary: "Look up what the user said before", risk: .read)

    func run(_ call: ToolCall) async throws -> String {
        var found: [CaptureResult] = []
        for keyword in RecallQuery.keywords(from: call.text) {
            for match in await memory.search(keyword, limit: 3) where !found.contains(where: { $0.id == match.id }) {
                found.append(match)
            }
        }
        return try await RuleOrganizer().answer(call.text, from: found)
    }
}

/// Not offered to planners. A confirmed call must still match its real recorded user utterance.
private struct PersonalWriteTool: PikoTool {
    let name: String
    let memory: any Memory

    var descriptor: ToolDescriptor {
        ToolDescriptor(name: name, summary: "Change a confirmed personal fact", risk: .local)
    }

    func run(_ call: ToolCall) async throws -> String {
        guard call.tool == name, call.when == nil, call.timeKnown,
              let captureID = call.sourceCaptureID,
              let intent = PersonalIntent.parse(call.text) else {
            throw PersonalFactToolError.unverifiedOrigin
        }
        let source: MemoryTurn
        do {
            source = try await memory.captureTurn(forCapture: captureID)
        } catch PersonalMemoryError.sourceCaptureMissing {
            throw PersonalFactToolError.unverifiedOrigin
        }
        guard source.role == .user, source.session == captureID,
              PersonalIntent.parse(source.text) == intent else {
            throw PersonalFactToolError.unverifiedOrigin
        }
        do {
            switch intent {
            case .remember(let key, let subject, let value) where name == ToolName.remember:
                _ = try await memory.setFact(
                    MemoryFactInput(key: key, value: value, sourceTurn: source.lsn,
                                    confidence: 1, lastUsed: .now),
                    ifLSN: call.expectedFactLSN
                )
                return "Remembered: your \(subject) is \(value)"
            case .forget(let key, let subject) where name == ToolName.forget:
                guard let revision = call.expectedFactLSN else {
                    throw PersonalFactToolError.unverifiedOrigin
                }
                try await memory.forgetFact(forKey: key, ifLSN: revision)
                return "Forgot what I saved about your \(subject)"
            default:
                throw PersonalFactToolError.unverifiedOrigin
            }
        } catch PersonalMemoryError.factConflict {
            throw PersonalFactToolError.changedSinceConfirmation
        }
    }
}
