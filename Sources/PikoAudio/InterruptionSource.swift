import Foundation

/// Something that can pull `SessionCoordinator`'s mic out from under it — a call, another app,
/// a route change, or low power mode. iOS does not distinguish "call" from "another app took the
/// session", so this doesn't try to either.
public enum InterruptionEvent: Sendable, Equatable {
    case began
    case ended(shouldResume: Bool)
    case routeChanged
    case lowPowerModeChanged(enabled: Bool)
}

public protocol InterruptionSource: Sendable {
    var events: AsyncStream<InterruptionEvent> { get }
}

/// Permanent no-op conformer. The correct default for previews and any context that deliberately
/// wants interruption monitoring disabled — not a placeholder to delete once Plan 03-02 lands.
public final class NullInterruptionSource: InterruptionSource, Sendable {
    public init() {}

    public var events: AsyncStream<InterruptionEvent> {
        AsyncStream { _ in }
    }
}
