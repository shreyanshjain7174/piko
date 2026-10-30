import Foundation
import PikoKit

public struct ToolOutcome: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case done(String), skipped(String), failed(String)
    }
    public var call: ToolCall
    public var status: Status
}

/// Runs a plan safely: only registered tools, at most `maxSteps`, and anything that changes
/// another app (`.external`) only after `approve` says yes. Planners propose; this decides.
public struct ToolHarness: Sendable {
    public let tools: [String: any PikoTool]
    public let maxSteps: Int

    public init(tools: [any PikoTool], maxSteps: Int = 5) {
        self.tools = Dictionary(tools.map { ($0.descriptor.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.maxSteps = maxSteps
    }

    public var descriptors: [ToolDescriptor] {
        ToolName.all.compactMap { tools[$0]?.descriptor }
    }

    /// What planners may propose. Read-only tools serve the separate recall path; offering them
    /// to the planner made it search history for ordinary requests.
    public var actionDescriptors: [ToolDescriptor] {
        descriptors.filter { $0.risk != .read }
    }

    public func run(_ plan: [ToolCall], approve: @Sendable (ToolCall) async -> Bool) async -> [ToolOutcome] {
        var outcomes: [ToolOutcome] = []
        for call in plan.prefix(maxSteps) {
            guard let tool = tools[call.tool] else {
                outcomes.append(.init(call: call, status: .skipped("Piko can't do that yet")))
                continue
            }
            if tool.descriptor.risk == .external, !(await approve(call)) {
                outcomes.append(.init(call: call, status: .skipped("Not approved")))
                continue
            }
            do {
                outcomes.append(.init(call: call, status: .done(try await tool.run(call))))
            } catch let error as PersonalFactToolError {
                outcomes.append(.init(call: call, status: .failed(error.userMessage)))
            } catch {
                outcomes.append(.init(call: call, status: .failed("That didn't work")))
            }
        }
        return outcomes
    }
}

/// Tidies a planned step's text into what the tool should show, using only spoken words.
enum StepText {
    static let commandLeads = ["nudge me", "remind me", "ping me", "ask me", "check in with me", "check in"]

    static func tidy(_ text: String, tool: String, now: Date) -> String {
        var text = SpokenDate.removing(from: text, now: now).text
        let lowered = text.lowercased()
        switch tool {
        case ToolName.shortcut:
            for lead in ["run my ", "run the ", "run ", "my ", "the "] where text.lowercased().hasPrefix(lead) {
                text = String(text.dropFirst(lead.count))
            }
            if text.lowercased().hasSuffix(" shortcut") { text = String(text.dropLast(" shortcut".count)) }
        case ToolName.checkIn:
            if let lead = commandLeads.first(where: lowered.hasPrefix) {
                text = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
                if text.lowercased().hasPrefix("to ") { text = "Time " + text }
            }
        default:
            break
        }
        return RuleOrganizer.capitalized(text.trimmingCharacters(in: .whitespaces))
    }
}

/// Free planner for every iPhone: files with an `Organizer`, then maps items onto offered tools.
public struct OrganizerPlanner: Planner {
    let organizer: any Organizer

    public init(organizer: any Organizer) { self.organizer = organizer }

    public func plan(_ request: String, tools: [ToolDescriptor], now: Date) async throws -> [ToolCall] {
        let offered = Set(tools.map(\.name))
        return try await organizer.organize(request, now: now).compactMap { item in
            let preferred = switch item.kind {
            case .reminder: ToolName.reminder
            case .note: ToolName.note
            case .journal: ToolName.journal
            }
            guard let tool = [preferred, ToolName.note].first(where: offered.contains) else { return nil }
            let isReminder = tool == ToolName.reminder
            return ToolCall(tool: tool, text: item.text, when: isReminder ? item.due : nil,
                            timeKnown: isReminder ? item.dueHasTime : true)
        }
    }
}

/// Model-backed planner. The model only proposes steps; unknown tools, unspoken content and
/// unspoken dates are dropped, and any failure falls back to the free rule planner.
public struct ModelPlanner: Planner {
    public struct Draft: Sendable, Equatable {
        public var tool: String
        public var text: String
        public var when: String?
        public init(tool: String, text: String, when: String?) {
            self.tool = tool
            self.text = text
            self.when = when
        }
    }

    public typealias Generate = @Sendable (_ request: String, _ tools: [ToolDescriptor]) async throws -> [Draft]

    private let generate: Generate
    private let fallback = OrganizerPlanner(organizer: RuleOrganizer())

    public init(generate: Generate? = nil) {
        self.generate = generate ?? Self.defaultGenerate
    }

    public func plan(_ request: String, tools: [ToolDescriptor], now: Date) async throws -> [ToolCall] {
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !PlanRepair.isFillerOnly(request) else { return [] }
        let offered = Set(tools.map(\.name))
        let drafts: [Draft]
        do {
            drafts = try await generate(request, tools)
        } catch {
            return try await fallback.plan(request, tools: tools, now: now)
        }
        let clauses = PlanRepair.clauses(request)
        var steps: [(position: Int, call: ToolCall)] = []
        for draft in drafts {
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard offered.contains(draft.tool), !text.isEmpty, !PlanRepair.isFillerOnly(text),
                  ModelOrganizer.isGrounded(text, in: request) else { continue }
            let position = PlanRepair.clauseIndex(for: text, in: clauses)
            let clause = position.map { clauses[$0] } ?? request
            var tool = draft.tool
            if PlanRepair.isIdea(clause), tool != ToolName.note, offered.contains(ToolName.note) {
                tool = ToolName.note
            }
            // Dates come only from the step's own clause: its text, the model's grounded phrase,
            // or a time spoken in that clause. Notes and journal entries never carry dates.
            var when: SpokenWhen?
            if PlanRepair.timedTools.contains(tool) {
                let fromText = SpokenDate.removing(from: text, now: now).when
                let fromPhrase = draft.when.flatMap { phrase in
                    ModelOrganizer.isGrounded(phrase, in: clause)
                        ? SpokenDate.resolve(phrase, context: clause, now: now) : nil
                }
                let fromClause = SpokenDate.resolve(clause, context: clause, now: now)
                let candidates = [fromClause, fromPhrase, fromText].compactMap { $0 }
                when = candidates.first(where: \.hasTime) ?? candidates.first
            }
            let tidied = StepText.tidy(text, tool: tool, now: now)
            guard !tidied.isEmpty, !PlanRepair.isFillerOnly(tidied),
                  !steps.contains(where: { $0.call.text.caseInsensitiveCompare(tidied) == .orderedSame }) else { continue }
            steps.append((position ?? clauses.count,
                          ToolCall(tool: tool, text: tidied, when: when?.date, timeKnown: when?.hasTime ?? true)))
        }
        if offered.contains(ToolName.journal) {
            let covered = Set(steps.map(\.position))
            let noteOnly = covered.filter { position in
                steps.filter { $0.position == position }.allSatisfy { $0.call.tool == ToolName.note }
            }
            for missed in PlanRepair.missedJournal(clauses: clauses, covered: covered, noteOnly: noteOnly, now: now) {
                steps.removeAll { missed.absorbed.contains($0.position) }
                steps.append((missed.position, ToolCall(tool: ToolName.journal, text: missed.text)))
            }
        }
        let calls = steps.enumerated()
            .sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
            .map(\.element.call)
        return calls.isEmpty ? try await fallback.plan(request, tools: tools, now: now) : calls
    }

    private static let defaultGenerate: Generate = { request, tools in
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return try await FoundationModelsPlanning.plan(request, tools: tools)
        }
        #endif
        throw PikoError.brainUnavailable("Foundation Models requires iOS 26")
    }
}
