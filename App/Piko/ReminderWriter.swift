import EventKit
import Foundation
import PikoKit

/// Writes filed reminders into the user's Apple Reminders, only after they tap Save.
@MainActor
final class ReminderWriter {
    enum Failure: Error {
        case accessDenied, noReminderList
        var message: String {
            switch self {
            case .accessDenied: "Piko needs Reminders access to save reminders. You can allow it in Settings."
            case .noReminderList: "Create a list in Reminders first, then try again."
            }
        }
    }

    private let store = EKEventStore()

    func add(_ items: [DumpItem]) async throws {
        guard !items.isEmpty else { return }
        guard try await store.requestFullAccessToReminders() else { throw Failure.accessDenied }
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noReminderList }
        for item in items {
            let reminder = EKReminder(eventStore: store)
            reminder.title = item.text
            reminder.calendar = list
            if let due = item.due {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            try store.save(reminder, commit: false)
        }
        try store.commit()
    }
}
