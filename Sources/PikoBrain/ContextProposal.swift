import Foundation
import PikoKit

/// A candidate only; persistence requires a separate explicit confirmation.
public struct ContextProposal: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case fact, person, preference, routine }

    public let kind: Kind
    public let entityName: String?
    public let key: String
    public let label: String
    public let value: String
    public let quote: String
    public let sourceTurn: MemoryTurn

    public init(kind: Kind, entityName: String?, key: String, label: String,
                value: String, quote: String, sourceTurn: MemoryTurn) {
        self.kind = kind
        self.entityName = entityName
        self.key = key
        self.label = label
        self.value = value
        self.quote = quote
        self.sourceTurn = sourceTurn
    }
}

public protocol ContextProposer {
    func propose(from source: MemoryTurn) -> [ContextProposal]
}

public protocol ContextProposalGating {
    func admit(_ proposal: ContextProposal, source: MemoryTurn) throws
}

public enum ProposalGateError: Error, Equatable, Sendable {
    case invalidSource, invalidKey, ungroundedQuote, ungroundedValue, sensitiveContent
}

/// The same trust boundary applies to future model-based and deterministic proposers.
public struct ProposalGate: ContextProposalGating {
    public init() {}

    public func admit(_ proposal: ContextProposal, source: MemoryTurn) throws {
        guard source.role == .user, proposal.sourceTurn == source else {
            throw ProposalGateError.invalidSource
        }
        guard (try? MemoryFact.validateKey(proposal.key)) != nil,
              !proposal.key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw ProposalGateError.invalidKey }
        guard !proposal.quote.isEmpty, source.text.contains(proposal.quote) else {
            throw ProposalGateError.ungroundedQuote
        }
        guard !proposal.value.isEmpty, proposal.quote.contains(proposal.value) else {
            throw ProposalGateError.ungroundedValue
        }
        guard SensitiveContent.verdict(label: proposal.label + " " + proposal.key,
                                       value: proposal.value) == .safe,
              SensitiveContent.verdict(label: proposal.label, value: proposal.quote) == .safe
        else { throw ProposalGateError.sensitiveContent }
    }
}

/// Independent oracle: returns invalid candidates a supplied gate mistakenly accepts.
public enum ProposalGateAudit {
    public static func violations(gate: any ContextProposalGating, proposer: any ContextProposer,
                                  fixtures: [MemoryTurn]) -> [ContextProposal] {
        fixtures.flatMap { source in
            proposer.propose(from: source).filter { candidate in
                let invalid = source.role != .user || candidate.sourceTurn != source
                    || candidate.key.isEmpty || candidate.key != candidate.key.trimmingCharacters(in: .whitespacesAndNewlines)
                    || candidate.key.utf8.count > 512
                    || candidate.key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                    || !source.text.contains(candidate.quote) || candidate.quote.isEmpty
                    || candidate.value.isEmpty || !candidate.quote.contains(candidate.value)
                    || SensitiveContent.verdict(label: candidate.label + " " + candidate.key,
                                                value: candidate.value) != .safe
                    || SensitiveContent.verdict(label: candidate.label, value: candidate.quote) != .safe
                guard invalid else { return false }
                do {
                    try gate.admit(candidate, source: source)
                    return true
                } catch { return false }
            }
        }
    }
}
