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
    private let audioLevelMonitor: AudioLevelMonitor
    private let audioSession: AudioSessionAccess
    private let relay = AudioBufferRelay()
    /// A ready-but-unused session releases the microphone after this long, so Piko is only
    /// live (mic indicator, Dynamic Island) around actual dictation.
    private let idleTimeout: Duration
    private var idleTask: Task<Void, Never>?

    private var sessionEpoch = 0
    public private(set) var currentPhase: SessionPhase = .idle
    private var heartbeatTask: Task<Void, Never>?
    /// Recreated on foreground arming after the session is active. An engine
    /// built before `AVAudioSession.setActive(true)` often has a 0 Hz input node.
    private var engine = AVAudioEngine()
    /// True only while a tap is installed. `removeTap` without a matching install crashes.
    private var tapInstalled = false
    /// Simulator-only PCM source; production never substitutes silence for failed hardware.
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
                audioSession: AudioSessionAccess = .system,
                idleTimeout: Duration = .seconds(300),
                isForeground: @escaping @MainActor @Sendable () -> Bool) {
        self.channel = channel
        self.audioLevelMonitor = AudioLevelMonitor(channel: audioLevels)
        self.interruptions = interruptions
        self.isForeground = isForeground
        self.audioSession = audioSession
        self.idleTimeout = idleTimeout
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
        guard currentPhase == .idle else { return }

        sessionEpoch += 1

        // `disarm()` finishes the previous sequence. A fresh arm must publish a fresh stream
        // or a same-process re-arm would run an audio engine whose STT input is already closed.
        if currentPhase == .idle {
            buffersContinuation.finish()
            (buffers, buffersContinuation) = AsyncStream.makeStream()
        }

        try audioSession.activate()
        do {
            try startAudioInput()
        } catch {
            do {
                try audioSession.deactivate()
            } catch {
                print("SessionCoordinator: failed to release audio after startup failure")
            }
            throw error
        }

        currentPhase = .armed
        broadcastPhase()
        writeChannelState(phase: .armed)
        scheduleIdleRelease()

        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.writeChannelState(phase: self.currentPhase)
            }
        }
    }

    public func disarm() async {
        idleTask?.cancel()
        idleTask = nil
        audioLevelMonitor.stop()
        heartbeatTask?.cancel()
        heartbeatTask = nil

        silencePumpTask?.cancel()
        silencePumpTask = nil
        relay.finish()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        buffersContinuation.finish()

        do {
            try audioSession.deactivate()
        } catch {
            print("SessionCoordinator: audio session deactivation failed (\(type(of: error)))")
        }

        currentPhase = .idle
        broadcastPhase()
        writeChannelState(phase: .idle)
    }

    private func scheduleIdleRelease() {
        idleTask?.cancel()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.currentPhase == .armed else { return }
            await self.disarm()
        }
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
        idleTask?.cancel()
        idleTask = nil

        buffersContinuation.finish()
        (buffers, buffersContinuation) = AsyncStream.makeStream()
        relay.begin(buffers: buffersContinuation, levels: audioLevelMonitor.start())

        currentPhase = .capturing
        broadcastPhase()
        writeChannelState(phase: .capturing)
    }

    private func startAudioInput() throws {
        #if targetEnvironment(simulator)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw PikoError.audioUnavailable
        }
        startSilencePump(format: format)
        #else
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        let hardwareLive = hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0
        guard hardwareLive else { throw PikoError.audioUnavailable }
        let format = hardwareFormat

        let relay = self.relay
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: relay.makeTap())
        tapInstalled = true

        engine.prepare()

        do {
            try engine.start()
        } catch {
            audioLevelMonitor.stop()
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            currentPhase = .armed
            throw PikoError.sessionInterrupted
        }
        #endif
    }

    private func startSilencePump(
        format: AVAudioFormat
    ) {
        silencePumpTask?.cancel()
        // Detached: SessionCoordinator is @MainActor; an inherited Task would
        // starve while other suites occupy the main actor and miss the 2s probe.
        let relay = self.relay
        silencePumpTask = Task.detached {
            while !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
                    return
                }
                buffer.frameLength = 1024
                relay.receive(buffer)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    public func stopCapture() async {
        audioLevelMonitor.stop()
        relay.finish()
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
        scheduleIdleRelease()
    }
}
#endif
