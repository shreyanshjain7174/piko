import Foundation
import Synchronization
import Testing
import PikoKit
@testable import PikoBrain

@Suite
struct RewriteBudgetTests {

    @Test func operationInsideBudgetReturnsValue() async throws {
        let value = try await withRewriteBudget(.milliseconds(200), clock: ManualClock()) {
            "ok"
        }
        #expect(value == "ok")
    }

    @Test func operationPastBudgetThrowsBrainBudgetExceeded() async {
        let clock = ManualClock()
        let gate = WorkerGate()
        let result = Task {
            try await withRewriteBudget(.milliseconds(50), clock: clock) {
                await gate.wait()
                return "late"
            }
        }
        await gate.waitUntilWaiting()
        await clock.waitForSleeps(1)
        clock.advance(by: .milliseconds(51))
        do {
            _ = try await result.value
            Issue.record("expected PikoError.brainBudgetExceeded")
        } catch PikoError.brainBudgetExceeded(let milliseconds) {
            #expect(milliseconds == 50)
            #expect(await gate.isWaiting)
        } catch {
            Issue.record("wrong error: \(error)")
        }
        await gate.release()
    }

    @Test func cancellationIgnoringWorkThrowsAtBudgetNotAfterFinish() async {
        let clock = ManualClock()
        let gate = WorkerGate()
        let result = Task {
            try await withRewriteBudget(.milliseconds(80), clock: clock) {
                // The gate ignores cancellation: only the test can release this worker.
                await gate.wait()
                return "ignored"
            }
        }
        await gate.waitUntilWaiting()
        await clock.waitForSleeps(1)
        clock.advance(by: .milliseconds(80))
        do {
            _ = try await result.value
            Issue.record("expected PikoError.brainBudgetExceeded")
        } catch PikoError.brainBudgetExceeded(let milliseconds) {
            #expect(milliseconds == 80)
            #expect(await gate.isWaiting)
        } catch {
            Issue.record("wrong error: \(error)")
        }
        await gate.release()
    }

    @Test func operationErrorPropagatesUnchanged() async {
        struct Boom: Error {}
        do {
            _ = try await withRewriteBudget(.milliseconds(500), clock: ManualClock()) {
                throw Boom()
            }
            Issue.record("expected Boom")
        } catch is Boom {
            // propagated unchanged
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: - Battle test: many concurrent races, mixed pass/timeout, each isolated.
    // RewriteBudgetRaceState is constructed fresh per call (no shared/static state).

    @Test func fiftyConcurrentBudgetRacesEachGetTheirOwnCorrectOutcome() async {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for i in 0..<50 {
                group.addTask {
                    let clock = ManualClock()
                    let shouldTimeout = i % 2 == 0
                    if shouldTimeout {
                        let gate = WorkerGate()
                        let result = Task {
                            try await withRewriteBudget(.milliseconds(60), clock: clock) {
                                await gate.wait()
                                return i
                            }
                        }
                        await gate.waitUntilWaiting()
                        await clock.waitForSleeps(1)
                        clock.advance(by: .milliseconds(61))
                        let correct: Bool
                        do {
                            _ = try await result.value
                            correct = false
                        } catch PikoError.brainBudgetExceeded {
                            correct = await gate.isWaiting
                        } catch {
                            correct = false
                        }
                        await gate.release()
                        return (i, correct)
                    }
                    do {
                        let value = try await withRewriteBudget(.milliseconds(60), clock: clock) { i }
                        return (i, value == i)
                    } catch {
                        return (i, false)
                    }
                }
            }
            var mismatches: [Int] = []
            for await (index, correct) in group where !correct {
                mismatches.append(index)
            }
            #expect(mismatches.isEmpty, "cross-contaminated race state at indices: \(mismatches)")
        }
    }
}

/// Test-only clock. Sleepers are registered under the same lock used by advance,
/// so advancing cannot slip between a deadline check and its registration.
private final class ManualClock: Clock, Sendable {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Duration
        let token: SleepToken
    }

    private struct Storage {
        var time: Duration = .zero
        var sleepers: [UUID: Sleeper] = [:]
        var registrations = 0
        var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(Storage())
    var now: Instant { state.withLock { Instant(offset: $0.time) } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        let token = SleepToken()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (complete, observers) = state.withLock { storage -> (Bool, [CheckedContinuation<Void, Never>]) in
                    let registered = token.register(continuation)
                    storage.registrations += 1
                    let observers = storage.observers.filter { $0.0 <= storage.registrations }.map(\.1)
                    storage.observers.removeAll { $0.0 <= storage.registrations }
                    if registered && storage.time < deadline.offset {
                        storage.sleepers[id] = Sleeper(deadline: deadline.offset, token: token)
                        return (false, observers)
                    }
                    return (registered, observers)
                }
                for observer in observers { observer.resume() }
                if complete { token.finish() }
            }
        } onCancel: {
            state.withLock { _ = $0.sleepers.removeValue(forKey: id) }
            token.cancel()
        }
    }

    func advance(by duration: Duration) {
        let expired = state.withLock { storage -> [SleepToken] in
            storage.time += duration
            let ids = storage.sleepers.filter { $0.value.deadline <= storage.time }.map(\.key)
            return ids.compactMap { storage.sleepers.removeValue(forKey: $0)?.token }
        }
        for token in expired { token.finish() }
    }

    func waitForSleeps(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { storage -> Bool in
                if storage.registrations >= count { return true }
                storage.observers.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// Cancellation and deadline may race with both registration and each other.
/// The token guarantees the sleeper continuation resumes exactly once.
private final class SleepToken: Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Void, Error>)
        case cancelled
        case completed
    }

    private let state = Mutex(State.pending)

    func register(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        let registered = state.withLock { state -> Bool in
            switch state {
            case .pending:
                state = .waiting(continuation)
                return true
            case .cancelled:
                return false
            case .waiting, .completed:
                preconditionFailure("sleep registered twice")
            }
        }
        if !registered { continuation.resume(throwing: CancellationError()) }
        return registered
    }

    func finish() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard case .waiting(let continuation) = state else { return nil }
            state = .completed
            return continuation
        }
        continuation?.resume()
    }

    func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            switch state {
            case .pending:
                state = .cancelled
                return nil
            case .waiting(let continuation):
                state = .cancelled
                return continuation
            case .cancelled, .completed:
                return nil
            }
        }
        continuation?.resume(throwing: CancellationError())
    }
}

/// Suspends even if cancelled. The test explicitly releases it after checking the deadline.
private actor WorkerGate {
    private var worker: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { worker != nil }

    func wait() async {
        await withCheckedContinuation { continuation in
            worker = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilWaiting() async {
        if isWaiting { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        worker?.resume()
        worker = nil
    }
}
