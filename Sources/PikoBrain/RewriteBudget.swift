import Foundation
import PikoKit

/// Hard-deadline race for rewrite inference.
///
/// Structured `withThrowingTaskGroup` scopes await remaining children at
/// exit, and `cancelAll()` is only cooperative. That cannot enforce a
/// deadline when model inference ignores cancellation. This helper resumes
/// a one-shot continuation as soon as either the operation or the budget
/// wins, then cancels the loser without awaiting it.
///
/// Ownership: raced work must own its mutable resources. Callers must not
/// touch those same resources after timeout without separately coordinating
/// completion. Production inference meets this because each invocation
/// creates a fresh local `LanguageModelSession`; neither `SystemBrain` nor
/// `CaptureCoordinator` retains or reuses that session. Cancellation is
/// cleanup, not deadline enforcement — a losing operation may continue if
/// it ignores cancellation.
func withRewriteBudget<T: Sendable>(
    _ budget: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let milliseconds = Int(
        budget.components.seconds * 1000
            + budget.components.attoseconds / 1_000_000_000_000_000
    )

    let state = RewriteBudgetRaceState<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            state.setContinuation(continuation)
            let work = Task {
                do {
                    let value = try await operation()
                    state.finish(.success(value))
                } catch {
                    state.finish(.failure(error))
                }
            }
            let timer = Task {
                try? await Task.sleep(for: budget)
                guard !Task.isCancelled else { return }
                state.finish(.failure(PikoError.brainBudgetExceeded(milliseconds: milliseconds)))
            }
            state.install(work: work, timer: timer)
        }
    } onCancel: {
        state.cancelFromParent()
    }
}

/// Lock-protected one-shot race state. Nested types cannot live inside a
/// generic function, so this sits at file scope.
private final class RewriteBudgetRaceState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var pendingCancelWork = false
    private var pendingCancelTimer = false

    func install(work: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        self.work = work
        self.timer = timer
        let cancelWork = pendingCancelWork || done
        let cancelTimer = pendingCancelTimer || done
        lock.unlock()
        if cancelWork { work.cancel() }
        if cancelTimer { timer.cancel() }
    }

    func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
        let toResume: Result<T, Error>?
        lock.lock()
        if done {
            toResume = pending
            pending = nil
            self.continuation = nil
        } else if let pending {
            done = true
            toResume = pending
            self.pending = nil
            pendingCancelWork = true
            pendingCancelTimer = true
        } else {
            self.continuation = continuation
            toResume = nil
        }
        let work = self.work
        let timer = self.timer
        lock.unlock()
        if let toResume {
            resumeContinuation(continuation, with: toResume)
            work?.cancel()
            timer?.cancel()
        }
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        pendingCancelWork = true
        pendingCancelTimer = true
        let continuation = self.continuation
        self.continuation = nil
        let work = self.work
        let timer = self.timer
        if continuation == nil {
            pending = result
        }
        lock.unlock()
        if let continuation {
            resumeContinuation(continuation, with: result)
        }
        work?.cancel()
        timer?.cancel()
    }

    func cancelFromParent() {
        finish(.failure(CancellationError()))
    }

    private func resumeContinuation(
        _ continuation: CheckedContinuation<T, Error>,
        with result: Result<T, Error>
    ) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
