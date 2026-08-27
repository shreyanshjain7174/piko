import Foundation
import PikoKit

/// Cross-process signalling over Darwin notifications, payloads over the App Group container.
///
/// Darwin notifications carry no data and no delivery guarantee, which is fine: they are a
/// doorbell. The payload always goes through a file in the shared container, so a missed
/// notification degrades to "the keyboard notices on its next poll" rather than data loss.
public final class DarwinChannel: SessionChannel, @unchecked Sendable {

    private let container: URL
    private let center = CFNotificationCenterGetDarwinNotifyCenter()
    private var continuations: [UUID: AsyncStream<Signal>.Continuation] = [:]
    private let lock = NSLock()

    public init?(groupID: String = AppGroup.identifier) {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        self.container = url
        observeAll()
    }

    // MARK: signalling

    public func post(_ signal: Signal) {
        CFNotificationCenterPostNotification(
            center, CFNotificationName(signal.rawValue as CFString), nil, nil, true)
    }

    public var signals: AsyncStream<Signal> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    private func observeAll() {
        for signal in Signal.allCases {
            let observer = Unmanaged.passUnretained(self).toOpaque()
            CFNotificationCenterAddObserver(
                center, observer,
                { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let channel = Unmanaged<DarwinChannel>.fromOpaque(observer).takeUnretainedValue()
                    guard let signal = Signal(rawValue: name.rawValue as String) else { return }
                    channel.broadcast(signal)
                },
                signal.rawValue as CFString, nil, .deliverImmediately)
        }
    }

    private func broadcast(_ signal: Signal) {
        let sinks = lock.withLock { Array(continuations.values) }
        for sink in sinks { sink.yield(signal) }
    }

    // MARK: payloads

    public func readState() -> SessionState? { read(AppGroup.stateFile) }
    public func writeState(_ state: SessionState) { write(state, to: AppGroup.stateFile, signal: .stateChanged) }
    public func readDraft() -> CaptureDraft? { read(AppGroup.draftFile) }
    public func writeDraft(_ draft: CaptureDraft) { write(draft, to: AppGroup.draftFile, signal: .draftUpdated) }
    public func readResult() -> CaptureResult? { read(AppGroup.resultFile) }
    public func writeResult(_ result: CaptureResult) { write(result, to: AppGroup.resultFile, signal: .resultReady) }

    private func read<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: container.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to name: String, signal: Signal) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        // Atomic: the reader is another process and may be mid-read.
        try? data.write(to: container.appendingPathComponent(name), options: .atomic)
        post(signal)
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
