import Foundation
import PikoAudio

final class MockInterruptionSource: InterruptionSource, Sendable {
    private let continuation: AsyncStream<InterruptionEvent>.Continuation
    let events: AsyncStream<InterruptionEvent>

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func send(_ event: InterruptionEvent) {
        continuation.yield(event)
    }
}
