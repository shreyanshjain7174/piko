import BackgroundTasks
import Foundation
import PikoKit

/// Tier-1 slot: opportunistic memory maintenance while charging. Nothing polls, nothing
/// runs on a timer — the system grants the window or the work waits (C10 by construction).
private final class TaskBox: @unchecked Sendable {
    var task: BGProcessingTask?
}

enum MemoryMaintenance {
    static let taskIdentifier = "dev.piko.memory.maintenance"

    /// Must run before the app finishes launching (BGTaskScheduler contract).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            scheduleNext()
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // BGProcessingTask predates Sendable; setTaskCompleted is safe off-main.
            let box = TaskBox()
            box.task = processing
            let work = Task {
                await AppComposition.shared.memory.indexNewResults()
                box.task?.setTaskCompleted(success: true)
            }
            processing.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleNext() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresExternalPower = true
        request.earliestBeginDate = Date().addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
