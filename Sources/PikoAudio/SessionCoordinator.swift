#if os(iOS)
import AVFAudio
import UIKit
import Foundation
import PikoKit

/// Owns `AVAudioSession`/`AVAudioEngine`. The first real `ArmedSession` conformer — see
/// `ArmedSession.swift` for the contract this implements unchanged.
@MainActor
public final class SessionCoordinator: ArmedSession {

    private let channel: any SessionChannel
    private let interruptions: any InterruptionSource
    private let isForeground: @MainActor @Sendable () -> Bool
    private let audioLevelMonitor: AudioLevelMonitor

    private var sessionEpoch = 0
    public private(set) var currentPhase: SessionPhase = .idle
    private var heartbeatTask: Task<Void, Never>?
    /// Recreated on each `startCapture()` after the session is active. An engine
    /// built before `AVAudioSession.setActive(true)` often has a 0 Hz input node.
    private var engine = AVAudioEngine()
    /// True only while a tap is installed. `removeTap` without a matching install crashes.
    private var tapInstalled = false
    /// Yields silent PCM when the input node reports 0 Hz (Simulator / pre-I/O). The
    /// hardware tap never fires in that state; 05-02 still needs a live buffer stream.
    private var silencePumpTask: Task<Void, Never>?

    /// Fanned out to every independent subscriber — `phase` hands back a fresh stream per
    /// access, not one shared continuation, so two simultaneous observers (e.g. the app's UI
    /// and `LiveActivityController`) each see every emission instead of racing for it.
    private var phaseSubscribers: [UUID: AsyncStream<SessionPhase>.Continuation] = [:]
    private var buffersContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    public private(set) var buffers: AsyncStream<AVAudioPCMBuffer>

    public var phase: AsyncStream<SessionPhase> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.phaseSubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.phaseSubscribers[id] = nil
                }
            }
        }
    }

    public init(channel: any SessionChannel,
                interruptions: any InterruptionSource,
                audioLevels: (any AudioLevelChannel)? = nil,
                isForeground: @escaping @MainActor @Sendable () -> Bool) {
        self.channel = channel
        self.audioLevelMonitor = AudioLevelMonitor(channel: audioLevels)
        self.interruptions = interruptions
        self.isForeground = isForeground
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

        // `disarm()` finishes the previous sequence. A fresh arm must publish a fresh stream
        // or a same-process re-arm would run an audio engine whose STT input is already closed.
        if currentPhase == .idle {
            buffersContinuation.finish()
            (buffers, buffersContinuation) = AsyncStream.makeStream()
        }

        guard AVAudioApplication.shared.recordPermission != .denied else {
            throw PikoError.microphoneDenied
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            throw PikoError.audioUnavailable
        }

        currentPhase = .armed
        broadcastPhase()
        writeChannelState(phase: .armed)

        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                // Adaptive: 2s in the foreground (keyboard responsiveness), 4s in the
                // background — half the wakeups, still inside the 5s isLive tolerance
                // the keyboard's "tap to arm" fallback depends on.
                let background = UIApplication.shared.applicationState != .active
                try? await Task.sleep(for: background ? .seconds(4) : .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.writeChannelState(phase: self.currentPhase)
            }
        }
    }

    public func disarm() async {
        audioLevelMonitor.stop()
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
        broadcastPhase()
        writeChannelState(phase: .idle)
    }

    private func broadcastPhase() {
        for continuation in phaseSubscribers.values {
            continuation.yield(currentPhase)
        }
    }

    /// Phase and heartbeat are coordinator-owned. Profile and skin are user-owned
    /// and must survive arm / heartbeat / disarm publications.
    private func writeChannelState(phase: SessionPhase, heartbeat: Date = .now) {
        let existing = channel.readState()
        channel.writeState(SessionState(
            phase: phase,
            heartbeat: heartbeat,
            skin: existing?.skin ?? .cute,
            profile: existing?.profile ?? .message
        ))
    }

    public func startCapture() async throws {
        guard currentPhase == .armed else { throw PikoError.notArmed }

        buffersContinuation.finish()
        (buffers, buffersContinuation) = AsyncStream.makeStream()

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
        let levelContinuation = audioLevelMonitor.start()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            levelContinuation.yield(AudioLevelMonitor.measure(buffer))
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
            audioLevelMonitor.stop()
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
        broadcastPhase()
        writeChannelState(phase: .capturing)
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
        audioLevelMonitor.stop()
        silencePumpTask?.cancel()
        silencePumpTask = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        buffersContinuation.finish()
        currentPhase = .tidying
        broadcastPhase()
        writeChannelState(phase: .tidying)
    }

    public func finishTidying() {
        guard currentPhase == .tidying else { return }
        currentPhase = .armed
        broadcastPhase()
        writeChannelState(phase: .armed)
    }
}
#endif
