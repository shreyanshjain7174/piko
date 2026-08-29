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
}

/// Darwin notification names. Cross-process, no payload — the payload goes through the App Group.
public enum Signal: String, Sendable, CaseIterable {
    case captureStart = "dev.piko.capture.start"
    case captureStop  = "dev.piko.capture.stop"
    case draftUpdated = "dev.piko.draft.updated"
    case resultReady  = "dev.piko.result.ready"
    case stateChanged = "dev.piko.state.changed"
}

public enum SessionPhase: String, Codable, Sendable {
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

public struct CaptureResult: Codable, Sendable, Equatable {
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
    case message, email, note, code, agent

    public var styleHint: String {
        switch self {
        case .message: "Short and casual. Contractions fine. No greeting or sign-off."
        case .email:   "Polite and complete. Greeting and sign-off if the speaker implied one."
        case .note:    "Terse. Fragments fine. No pleasantries."
        case .code:    "Imperative mood, present tense, conventional-commit shape when it reads like a commit."
        case .agent:   "Unambiguous and structured for an AI agent to parse: resolve pronouns, make the subject and action explicit, no rhetorical filler."
        }
    }
}

public enum Skin: String, Codable, Sendable, CaseIterable {
    case cute, cool, hero, sparkle
}
