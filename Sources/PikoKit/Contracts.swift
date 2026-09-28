import Foundation

/// Identifiers shared by the app, the keyboard extension and the widget extension.
/// Change these in one place or the processes stop seeing each other.
public enum AppGroup {
    /// Must match `com.apple.security.application-groups` in every target's entitlements;
    /// mirrored by hand in `App/project.yml` since XcodeGen cannot read this constant.
    public static let identifier = "group.dev.piko.shared"
    public static let draftFile = "draft.json"
    public static let resultFile = "result.json"
    public static let stateFile = "state.json"
    public static let captureRequestFile = "capture-request.json"
    public static let stopRequestFile = "stop-request.json"
    public static let audioLevelFile = "audio-level.json"
}

/// Darwin notification names. Cross-process, no payload — the payload goes through the App Group.
public enum Signal: String, Sendable, CaseIterable {
    case captureStart  = "dev.piko.capture.start"
    case captureStop   = "dev.piko.capture.stop"
    case draftUpdated  = "dev.piko.draft.updated"
    case resultReady   = "dev.piko.result.ready"
    case stateChanged  = "dev.piko.state.changed"
    case stopRequested = "dev.piko.stop.requested"
    case captureRequested = "dev.piko.capture.requested"
    case audioLevelUpdated = "dev.piko.audio.level.updated"
}

/// A durable request created by a system surface before the container app starts capture.
/// The UUID prevents an older consumer from clearing a newer cross-process request.
public struct CaptureLaunchRequest: Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date

    public init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
    }
}

public enum SessionPhase: String, Codable, Sendable, Hashable, CaseIterable {
    case idle       // app not holding an audio session
    case armed      // session active, mic not capturing
    case capturing  // buffering audio
    case tidying    // capture finished, brain working
}

public struct SessionState: Codable, Sendable, Equatable {
    public var phase: SessionPhase
    public var heartbeat: Date
    public var skin: Skin
    public var profile: Profile

    public init(phase: SessionPhase = .idle,
                heartbeat: Date = .now,
                skin: Skin = .cute,
                profile: Profile = .message) {
        self.phase = phase
        self.heartbeat = heartbeat
        self.skin = skin
        self.profile = profile
    }

    /// The keyboard shows "tap to arm" rather than a mic button when this is false.
    /// The app is expected to refresh `heartbeat` at least every 2 seconds while armed.
    public func isLive(now: Date = .now, tolerance: TimeInterval = 5) -> Bool {
        phase != .idle && now.timeIntervalSince(heartbeat) < tolerance
    }
}

/// A streaming partial transcript.
///
/// `stablePrefix` is the number of leading characters the transcriber will not revise.
/// The keyboard inserts up to that point and only rewrites what follows — this is the
/// difference between text that arrives and text that thrashes.
public struct CaptureDraft: Codable, Sendable, Equatable {
    /// Bumped once per `arm()`, never reset mid-session. Compared before `sequence` so a
    /// new session's drafts always outrank a stale high-water mark left by the previous one.
    public var sessionEpoch: Int
    public var sequence: Int
    public var text: String
    public var stablePrefix: Int
    public var startedAt: Date

    public init(sessionEpoch: Int = 0, sequence: Int, text: String, stablePrefix: Int, startedAt: Date = .now) {
        self.sessionEpoch = sessionEpoch
        self.sequence = sequence
        self.text = text
        self.stablePrefix = stablePrefix
        self.startedAt = startedAt
    }

    /// The shared "is this newer" rule both processes must agree on. A `nil` previous draft is
    /// always superseded. A higher `sessionEpoch` always wins regardless of `sequence` — this is
    /// what closes the silent-drop bug where a new session's counter restarting at 0 would
    /// otherwise lose to the previous session's leftover high-water mark.
    public func isNewer(than previous: CaptureDraft?) -> Bool {
        guard let previous else { return true }
        if sessionEpoch != previous.sessionEpoch { return sessionEpoch > previous.sessionEpoch }
        return sequence > previous.sequence
    }
}

public enum Route: String, Codable, Sendable {
    case write    // text goes into the field the user is standing in
    case command  // an action to run — v0.2
    case recall   // a question about their own history — v0.2
}

public struct CaptureResult: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var raw: String          // what the transcriber heard, kept for edit-pair learning
    public var shipped: String      // what we inserted
    public var route: Route
    public var profile: Profile
    public var createdAt: Date
    public var timings: Timings

    public struct Timings: Codable, Sendable, Equatable {
        public var firstWordMS: Int
        public var transcribeMS: Int
        public var brainMS: Int
        public init(firstWordMS: Int = 0, transcribeMS: Int = 0, brainMS: Int = 0) {
            self.firstWordMS = firstWordMS
            self.transcribeMS = transcribeMS
            self.brainMS = brainMS
        }
    }

    public init(id: UUID = UUID(), raw: String, shipped: String, route: Route = .write,
                profile: Profile = .message, createdAt: Date = .now, timings: Timings = .init()) {
        self.id = id
        self.raw = raw
        self.shipped = shipped
        self.route = route
        self.profile = profile
        self.createdAt = createdAt
        self.timings = timings
    }
}

/// One correction the user made. The training signal for both the prompt and any later fine-tune.
public struct EditPair: Codable, Sendable, Equatable, Hashable {
    public var raw: String
    public var shipped: String
    public var final: String
    public var profile: Profile
    public var createdAt: Date

    public init(raw: String, shipped: String, final: String,
                profile: Profile = .message, createdAt: Date = .now) {
        self.raw = raw
        self.shipped = shipped
        self.final = final
        self.profile = profile
        self.createdAt = createdAt
    }
}

/// A tone. The keyboard cannot see the host app (CONSTRAINTS C7), so the user picks this.
public enum Profile: String, Codable, Sendable, CaseIterable {
    case message, email, note, code
    /// Shapes text a machine will parse for instructions. `.code` shapes text a human
    /// will read in a commit or a file.
    case agent

    /// The one human name per tone — shared by the keyboard's Tone menu and History rows
    /// so a profile never has two names across surfaces.
    public var displayName: String {
        switch self {
        case .message: "Casual"
        case .email:   "Email"
        case .note:    "Notes"
        case .code:    "Code"
        case .agent:   "Prompt"
        }
    }

    public var styleHint: String {
        switch self {
        case .message: "Short and casual. Contractions fine. No greeting or sign-off."
        case .email:   "Polite and complete. Greeting and sign-off if the speaker implied one."
        case .note:    "Terse. Fragments fine. No pleasantries."
        case .code:    "Imperative mood, present tense, conventional-commit shape when it reads like a commit."
        case .agent:   "Imperative, unambiguous, no filler words or hedging. State the concrete file/symbol/action if the speaker named one. No greeting, no pleasantries, no restating the obvious."
        }
    }
}

public enum Skin: String, Codable, Sendable, CaseIterable, Hashable {
    case cute, cool, hero, sparkle
}

/// How the keyboard starts capture when it becomes visible with an armed session.
/// `tapToTalk` is the default and the promise the product was built around; `auto`
/// is opt-in for people who arm the session and want it to fire the moment they
/// open any text field.
public enum CaptureMode: String, Codable, Sendable, CaseIterable {
    case tapToTalk
    case auto

    /// The silence watchdog is longer in tap-to-talk (walk-away dictation is
    /// intentional there) and much shorter in auto (a field that opened but no
    /// speech arrived should not leave the microphone hot).
    public var silenceTimeout: TimeInterval {
        switch self {
        case .tapToTalk: 15
        case .auto: 2.5
        }
    }

    public var displayName: String {
        switch self {
        case .tapToTalk: "Hold to talk"
        case .auto: "Auto"
        }
    }

    public var explainer: String {
        switch self {
        case .tapToTalk: "Press the mic to start, release to finish."
        case .auto: "Dictation starts the moment a text field opens."
        }
    }
}

/// Which transcriber the container app spins up. `onDevice` is the default and
/// stays true to the "Audio never leaves this phone" promise; `sarvamCloud` is
/// opt-in and requires the user to paste a key in Settings.
public enum TranscriberBackend: String, Codable, Sendable, CaseIterable {
    case onDevice
    case sarvamCloud

    public var displayName: String {
        switch self {
        case .onDevice: "On this iPhone"
        case .sarvamCloud: "Sarvam Cloud"
        }
    }

    public var explainer: String {
        switch self {
        case .onDevice: "Uses Apple’s on-device speech recognition. Nothing leaves your iPhone."
        case .sarvamCloud: "Sends recorded audio to Sarvam over HTTPS. Faster on some languages; requires an API key."
        }
    }

    public var leavesDevice: Bool { self == .sarvamCloud }
}

/// Cross-process settings backed by the App Group's shared UserDefaults so the
/// keyboard extension can read the current capture mode without a bridge round trip.
public enum CaptureModeStore {
    private static let modeKey = "dev.piko.captureMode"
    private static let backendKey = "dev.piko.transcriberBackend"

    /// Suite is the App Group by default; tests inject an isolated UserDefaults
    /// so persistence round-trips can be asserted without leaking into other tests.
    nonisolated(unsafe) private static var _defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.identifier)

    /// Test hook. Pass `nil` to reset to the App Group suite. Not for production use.
    public static func _setDefaults(_ defaults: UserDefaults?) {
        _defaults = defaults ?? UserDefaults(suiteName: AppGroup.identifier)
    }

    private static var defaults: UserDefaults? { _defaults }

    public static func read() -> CaptureMode {
        guard let raw = defaults?.string(forKey: modeKey),
              let mode = CaptureMode(rawValue: raw) else { return .tapToTalk }
        return mode
    }

    public static func write(_ mode: CaptureMode) {
        defaults?.set(mode.rawValue, forKey: modeKey)
    }

    public static func readBackend() -> TranscriberBackend {
        guard let raw = defaults?.string(forKey: backendKey),
              let backend = TranscriberBackend(rawValue: raw) else { return .onDevice }
        return backend
    }

    public static func writeBackend(_ backend: TranscriberBackend) {
        defaults?.set(backend.rawValue, forKey: backendKey)
    }
}
