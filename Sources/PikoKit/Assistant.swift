import Foundation

/// One thing Piko filed from a brain-dump.
public struct DumpItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case reminder, note, journal
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    /// Only set when the speaker said a date or time; never invented.
    public var due: Date?
    /// False when only a day was said, so the time part of `due` is a placeholder.
    public var dueHasTime: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, text: String, due: Date? = nil, dueHasTime: Bool = true,
                createdAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.text = text
        self.due = due
        self.dueHasTime = dueHasTime
        self.createdAt = createdAt
    }
}

/// Turns what the user said into filed items, and answers questions about their own history.
/// Free tiers run on-device; a premium cloud organizer can conform later.
public protocol Organizer: Sendable {
    func organize(_ text: String, now: Date) async throws -> [DumpItem]
    func answer(_ question: String, from history: [CaptureResult]) async throws -> String
}

/// Local store for filed notes and journal entries.
public protocol ItemStore: Sendable {
    func save(_ items: [DumpItem]) async
    func items(kind: DumpItem.Kind, limit: Int) async -> [DumpItem]
}

/// On-device count of filed brain-dumps, shown to testers for the kill-criterion check.
/// Never leaves the phone.
public struct DumpLog: @unchecked Sendable {
    static let key = "PikoBrainDumpDates"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var dates: [Date] {
        (defaults.array(forKey: Self.key) as? [Double] ?? []).map(Date.init(timeIntervalSince1970:))
    }

    public func record(at date: Date = .now) {
        let cutoff = date.addingTimeInterval(-30 * 86_400)
        let kept = (dates + [date]).filter { $0 >= cutoff }.map(\.timeIntervalSince1970)
        defaults.set(kept, forKey: Self.key)
    }

    public func countLastSevenDays(now: Date = .now) -> Int {
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        return dates.filter { $0 >= cutoff && $0 <= now }.count
    }
}

// MARK: - Tool harness contracts

/// How much a tool can affect the world. `external` changes another app and needs the user's OK.
public enum ToolRisk: String, Sendable {
    case read, local, external
}

public enum ToolName {
    public static let reminder = "reminder.create"
    public static let calendar = "calendar.create"
    public static let note = "note.save"
    public static let journal = "journal.save"
    public static let checkIn = "checkin.schedule"
    public static let shortcut = "shortcut.run"
    public static let search = "memory.search"
    public static let remember = "memory.remember"
    public static let forget = "memory.forget"
    /// Personal writes are intentionally absent: the model must never propose them.
    public static let all = [reminder, calendar, note, journal, checkIn, shortcut, search]
}

/// User-visible failures of an explicit, confirmed personal-memory action.
public enum PersonalFactToolError: Error, Equatable, Sendable {
    case unverifiedOrigin
    case changedSinceConfirmation

    public var userMessage: String {
        switch self {
        case .unverifiedOrigin:
            "I couldn't verify the original request. Please say it again."
        case .changedSinceConfirmation:
            "That saved fact changed. Please ask again and confirm the latest version."
        }
    }
}

/// One step of a plan. A single shape for every tool keeps planners model-agnostic.
public struct ToolCall: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var tool: String
    /// Title, note text, message, shortcut name or search query, depending on the tool.
    public var text: String
    /// Only set when the user said a date or time.
    public var when: Date?
    /// False when only a day was said ("Friday"); Piko asks for the time instead of guessing.
    public var timeKnown: Bool
    /// The persisted user capture that explicitly requested a personal-memory change.
    public var sourceCaptureID: UUID?
    /// Revision read before confirmation; nil means insert-only, never "overwrite anything".
    public var expectedFactLSN: Int64?

    public init(id: UUID = UUID(), tool: String, text: String, when: Date? = nil, timeKnown: Bool = true,
                sourceCaptureID: UUID? = nil, expectedFactLSN: Int64? = nil) {
        self.id = id
        self.tool = tool
        self.text = text
        self.when = when
        self.timeKnown = timeKnown
        self.sourceCaptureID = sourceCaptureID
        self.expectedFactLSN = expectedFactLSN
    }
}

public struct ToolDescriptor: Sendable, Equatable {
    public var name: String
    public var summary: String
    public var risk: ToolRisk

    public init(name: String, summary: String, risk: ToolRisk) {
        self.name = name
        self.summary = summary
        self.risk = risk
    }
}

public protocol PikoTool: Sendable {
    var descriptor: ToolDescriptor { get }
    /// Returns a short, user-facing description of what happened.
    func run(_ call: ToolCall) async throws -> String
}

/// Turns a spoken request into tool calls. Apple's model, an open SLM or a future cloud model
/// can conform; the harness, not the planner, decides what actually runs.
public protocol Planner: Sendable {
    func plan(_ request: String, tools: [ToolDescriptor], now: Date) async throws -> [ToolCall]
}
