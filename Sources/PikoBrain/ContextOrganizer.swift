import Foundation
import PikoKit

/// Staging reads only. A fact or entity is created exclusively after explicit confirmation.
public struct ContextOrganizer: Sendable {
    public enum Staged: Equatable, Sendable {
        case new(ContextProposal)
        case unchanged(ContextProposal, existing: MemoryFact)
        case conflict(ContextProposal, existing: MemoryFact)

        var proposal: ContextProposal {
            switch self {
            case .new(let proposal), .unchanged(let proposal, _), .conflict(let proposal, _): proposal
            }
        }

        var existing: MemoryFact? {
            switch self {
            case .new: nil
            case .unchanged(_, let existing), .conflict(_, let existing): existing
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case saved(MemoryFact)
        case unchanged(MemoryFact)
        case conflict(existing: MemoryFact)
    }

    public enum Resolution: Sendable { case replace, keep }

    private let memory: any Memory

    public init(memory: any Memory) { self.memory = memory }

    public func stage(_ proposal: ContextProposal,
                      admittedBy gate: any ContextProposalGating = ProposalGate()) async throws -> Staged {
        try await validate(proposal, admittedBy: gate)
        guard let existing = try await memory.fact(forKey: proposal.key) else { return .new(proposal) }
        return existing.value == proposal.value ? .unchanged(proposal, existing: existing)
                                                : .conflict(proposal, existing: existing)
    }

    /// `observedLSN` is the fact revision shown to the user, not the source utterance LSN.
    public func confirm(_ staged: Staged, observedLSN: Int64?) async throws -> Outcome {
        try await confirm(staged, observedLSN: observedLSN, allowReplace: false)
    }

    private func confirm(_ staged: Staged, observedLSN: Int64?,
                         allowReplace: Bool) async throws -> Outcome {
        let proposal = staged.proposal
        // Recheck even for a manually constructed Staged or a source turn removed since staging.
        try await validate(proposal, admittedBy: ProposalGate())
        let expected = staged.existing?.lsn
        guard observedLSN == expected else {
            throw PersonalMemoryError.factConflict(key: proposal.key, expectedLSN: observedLSN,
                                                   actualLSN: expected)
        }
        if case .conflict = staged, !allowReplace {
            guard let current = try await memory.fact(forKey: proposal.key) else {
                throw PersonalMemoryError.factConflict(key: proposal.key,
                                                       expectedLSN: expected, actualLSN: nil)
            }
            return .conflict(existing: current)
        }
        if case .unchanged = staged {
            let current = try await memory.fact(forKey: proposal.key)
            if current?.lsn == expected, let current { return .unchanged(current) }
            if let current { return .conflict(existing: current) }
            throw PersonalMemoryError.factConflict(key: proposal.key, expectedLSN: expected, actualLSN: nil)
        }
        let entityID = try await ensureEntity(for: proposal)
        let input = MemoryFactInput(key: proposal.key, value: proposal.value,
                                    sourceTurn: proposal.sourceTurn.lsn, confidence: 1,
                                    lastUsed: proposal.sourceTurn.at, entityID: entityID)
        do {
            return .saved(try await memory.setFact(input, ifLSN: expected))
        } catch PersonalMemoryError.factConflict {
            if let current = try await memory.fact(forKey: proposal.key) {
                return .conflict(existing: current)
            }
            throw PersonalMemoryError.factConflict(key: proposal.key, expectedLSN: expected, actualLSN: nil)
        }
    }

    public func resolve(_ decision: Resolution, on staged: Staged,
                        observedLSN: Int64?) async throws -> Outcome {
        switch decision {
        case .replace: return try await confirm(staged, observedLSN: observedLSN, allowReplace: true)
        case .keep:
            try await validate(staged.proposal, admittedBy: ProposalGate())
            guard let current = try await memory.fact(forKey: staged.proposal.key) else {
                throw PersonalMemoryError.factConflict(key: staged.proposal.key,
                                                       expectedLSN: observedLSN, actualLSN: nil)
            }
            return .unchanged(current)
        }
    }

    private func validate(_ proposal: ContextProposal,
                          admittedBy gate: any ContextProposalGating) async throws {
        try ProposalGate().admit(proposal, source: proposal.sourceTurn)
        try gate.admit(proposal, source: proposal.sourceTurn)
        guard let stored = try await memory.turn(lsn: proposal.sourceTurn.lsn),
              stored.lsn == proposal.sourceTurn.lsn,
              stored.session == proposal.sourceTurn.session,
              stored.role == .user, stored.text == proposal.sourceTurn.text,
              abs(stored.at.timeIntervalSince(proposal.sourceTurn.at)) < 0.000001
        else { throw ProposalGateError.invalidSource }
    }

    private func ensureEntity(for proposal: ContextProposal) async throws -> String? {
        guard let name = proposal.entityName else { return nil }
        let parts = proposal.key.split(separator: "/")
        guard parts.count == 3, parts[0] == "person", parts[1] == name.lowercased() else {
            throw ProposalGateError.invalidKey
        }
        let id = "person/" + String(parts[1])
        if try await memory.entity(id: id) == nil {
            do {
                try await memory.createEntity(MemoryEntity(id: id, name: name, kind: "person",
                                                           createdAt: proposal.sourceTurn.at))
            } catch PersonalMemoryError.entityAlreadyExists {
                // A concurrent confirmation created the same entity.
            }
        }
        return id
    }
}
