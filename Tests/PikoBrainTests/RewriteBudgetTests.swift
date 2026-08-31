import Foundation
import Testing
import PikoKit
@testable import PikoBrain

@Suite
struct RewriteBudgetTests {

    @Test func operationInsideBudgetReturnsValue() async throws {
        let value = try await withRewriteBudget(.milliseconds(200)) {
            "ok"
        }
        #expect(value == "ok")
    }

    @Test func operationPastBudgetThrowsBrainBudgetExceeded() async {
        do {
            _ = try await withRewriteBudget(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(2))
                return "late"
            }
            Issue.record("expected PikoError.brainBudgetExceeded")
        } catch PikoError.brainBudgetExceeded(let milliseconds) {
            #expect(milliseconds == 50)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func cancellationIgnoringWorkThrowsAtBudgetNotAfterFinish() async {
        let budget: Duration = .milliseconds(80)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await withRewriteBudget(budget) {
                let innerStart = ContinuousClock().now
                while ContinuousClock().now - innerStart < Duration.milliseconds(800) {
                    await Task.yield()
                }
                return "ignored"
            }
            Issue.record("expected PikoError.brainBudgetExceeded")
        } catch PikoError.brainBudgetExceeded {
            let elapsed = start.duration(to: clock.now)
            #expect(elapsed < budget + .milliseconds(150))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func operationErrorPropagatesUnchanged() async {
        struct Boom: Error {}
        do {
            _ = try await withRewriteBudget(.milliseconds(500)) {
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
    // RewriteBudgetRaceState is constructed fresh per call (no shared/static state), so
    // this proves that holds under real concurrency, not just by code inspection.

    @Test func fiftyConcurrentBudgetRacesEachGetTheirOwnCorrectOutcome() async {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for i in 0..<50 {
                group.addTask {
                    let shouldTimeout = i % 2 == 0
                    do {
                        let value = try await withRewriteBudget(.milliseconds(60)) {
                            if shouldTimeout {
                                try await Task.sleep(for: .seconds(2))
                            }
                            return i
                        }
                        return (i, !shouldTimeout && value == i)
                    } catch PikoError.brainBudgetExceeded {
                        return (i, shouldTimeout)
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
