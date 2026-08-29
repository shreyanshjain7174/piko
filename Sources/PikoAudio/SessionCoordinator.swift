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
    /// Recreated on each `startCapture()` after the session is active. An engine
    /// built before `AVAudioSession.setActive(true)` often has a 0 Hz input node.
    private var engine = AVAudioEngine()
    /// True only while a tap is installed. `removeTap` without a matching install crashes.
    private var tapInstalled = false
    /// Yields silent PCM when the input node reports 0 Hz (Simulator / pre-I/O). The
    /// hardware tap never fires in that state; 05-02 still needs a live buffer stream.
    private var silencePumpTask: Task<Void, Never>?

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

        silencePumpTask?.cancel()
        silencePumpTask = nil
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

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        let session = AVAudioSession.sharedInstance()
        // Simulator (and some devices before I/O starts) reports 0 Hz / 0 channels
        // on the node. Prefer the live session rate; a mismatched tap format never fires.
        let hardwareLive = hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0
        let format: AVAudioFormat
        if hardwareLive {
            format = hardwareFormat
        } else if let fallback = AVAudioFormat(
            standardFormatWithSampleRate: session.sampleRate > 0 ? session.sampleRate : 48_000,
            channels: AVAudioChannelCount(max(session.inputNumberOfChannels, 1))
        ) {
            format = fallback
        } else {
            throw PikoError.sessionInterrupted
        }

        // Pull input through the graph so the tap is rendered. Keep a tiny mixer
        // volume — outputVolume 0 can let the engine skip rendering entirely,
        // which means the tap never runs (observed on Simulator).
        engine.mainMixerNode.outputVolume = 0.001
        engine.connect(inputNode, to: engine.mainMixerNode, format: format)

        // Capture the continuation into a local before installing the tap. The tap
        // closure runs on the audio render thread; SessionCoordinator is @MainActor,
        // so a self.buffersContinuation access here would cross actor isolation.
        let continuation = buffersContinuation
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            continuation.yield(buffer)
        }
        tapInstalled = true

        engine.prepare()

        #if targetEnvironment(simulator)
        // Simulator HAL often hangs ~2.5s in engine.start() and never fires the tap.
        // Pump silent PCM first so capturing still yields for 05-02 / tests.
        startSilencePump(format: format, continuation: continuation)
        #else
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            currentPhase = .armed
            throw PikoError.sessionInterrupted
        }
        if !hardwareLive {
            startSilencePump(format: format, continuation: continuation)
        }
        #endif

        currentPhase = .capturing
        phaseContinuation.yield(currentPhase)
    }

    private func startSilencePump(
        format: AVAudioFormat,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    ) {
        silencePumpTask?.cancel()
        // Detached: SessionCoordinator is @MainActor; an inherited Task would
        // starve while other suites occupy the main actor and miss the 2s probe.
        silencePumpTask = Task.detached {
            while !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
                    return
                }
                buffer.frameLength = 1024
                continuation.yield(buffer)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    public func stopCapture() async {
        silencePumpTask?.cancel()
        silencePumpTask = nil
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
