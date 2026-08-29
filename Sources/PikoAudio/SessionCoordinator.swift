#if os(iOS)
import AVFAudio
import Foundation
import PikoKit

/// Owns `AVAudioSession`/`AVAudioEngine`. The first real `ArmedSession` conformer — see
/// `ArmedSession.swift` for the contract this implements unchanged.
@MainActor
public final class SessionCoordinator: ArmedSession {

    private let channel: any SessionChannel
    private let interruptions: any InterruptionSource
    private let isForeground: @MainActor @Sendable () -> Bool

    private var sessionEpoch = 0
    private var currentPhase: SessionPhase = .idle
    private var heartbeatTask: Task<Void, Never>?
    private let engine = AVAudioEngine()
    /// True only while a tap is installed. `removeTap` without a matching install crashes.
    private var tapInstalled = false

    private let phaseContinuation: AsyncStream<SessionPhase>.Continuation
    public let phase: AsyncStream<SessionPhase>
    private let buffersContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    public let buffers: AsyncStream<AVAudioPCMBuffer>

    public init(channel: any SessionChannel,
                interruptions: any InterruptionSource,
                isForeground: @escaping @MainActor @Sendable () -> Bool) {
        self.channel = channel
        self.interruptions = interruptions
        self.isForeground = isForeground
        (phase, phaseContinuation) = AsyncStream.makeStream()
        (buffers, buffersContinuation) = AsyncStream.makeStream()

        Task { [weak self] in
            guard let events = self?.interruptions.events else { return }
            for await event in events {
                guard let self else { return }
                switch event {
                case .began, .routeChanged, .lowPowerModeChanged(enabled: true):
                    await self.disarm()
                case .ended, .lowPowerModeChanged(enabled: false):
                    break
                }
            }
        }
    }

    public func arm() async throws {
        guard isForeground() else { throw PikoError.notForeground }

        sessionEpoch += 1

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, options: [.allowBluetoothHFP])
        try session.setActive(true)

        currentPhase = .armed
        phaseContinuation.yield(currentPhase)
        channel.writeState(SessionState(phase: .armed, heartbeat: .now))

        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.channel.writeState(SessionState(phase: self.currentPhase, heartbeat: .now))
            }
        }
    }

    public func disarm() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        buffersContinuation.finish()

        try? AVAudioSession.sharedInstance().setActive(false)

        currentPhase = .idle
        phaseContinuation.yield(currentPhase)
        channel.writeState(SessionState(phase: .idle, heartbeat: .now))
    }

    public func startCapture() async throws {
        guard currentPhase == .armed else { throw PikoError.notArmed }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // Capture the continuation into a local before installing the tap. The tap
        // closure runs on the audio render thread; SessionCoordinator is @MainActor,
        // so a self.buffersContinuation access here would cross actor isolation.
        let continuation = buffersContinuation
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            continuation.yield(buffer)
        }
        tapInstalled = true

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            currentPhase = .armed
            throw PikoError.sessionInterrupted
        }

        currentPhase = .capturing
        phaseContinuation.yield(currentPhase)
    }

    public func stopCapture() async {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        currentPhase = .armed
        phaseContinuation.yield(currentPhase)
    }
}
#endif
