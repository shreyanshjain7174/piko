import Foundation
import PikoKit

/// UIKit traits are mapped to these field kinds by the keyboard shell.
enum SuggestionFieldKind {
    case other, password, newPassword, oneTimeCode, creditCardNumber

    var isSensitive: Bool { self != .other }
}

/// The only field mutation available to suggestions; the host and tests supply this proxy.
@MainActor
protocol SuggestionProxy: AnyObject {
    var documentIdentifier: UUID? { get }
    var isSecureTextEntry: Bool { get }
    var fieldKind: SuggestionFieldKind { get }
    func insertText(_ text: String)
}

/// A one-shot capability issued only after the user taps the offered chip.
struct SuggestionConfirmToken: Equatable {
    let documentIdentifier: UUID
    let key: String
    let factLSN: Int64
    let revision: Int64
    fileprivate let nonce: UUID
}

/// No insertion is possible until a second, explicit confirmation tap.
/// The snapshot reader is the validated, metadata-cached store read; confirm always uses a fresh read.
@MainActor
final class SuggestionController {
    enum State: Equatable {
        case idle
        case offered(SuggestionSnapshot.Entry)
        case confirming(SuggestionSnapshot.Entry)
        case inserted
        case dismissed
    }

    private let proxy: any SuggestionProxy
    private let snapshotReader: @MainActor () -> SuggestionSnapshot
    private let freshSnapshotReader: @MainActor () -> SuggestionSnapshot
    private let suggestionsEnabled: @MainActor () -> Bool
    private var document: UUID?
    private var dismissedDocuments = Set<UUID>()
    private var pendingToken: SuggestionConfirmToken?
    private var offeredRevision: Int64?
    private var offeredEntries: [SuggestionSnapshot.Entry]?
    private(set) var state: State = .idle

    var offeredEntry: SuggestionSnapshot.Entry? {
        if case .offered(let entry) = state { return entry }
        return nil
    }

    var confirmingEntry: SuggestionSnapshot.Entry? {
        if case .confirming(let entry) = state { return entry }
        return nil
    }

    init(proxy: any SuggestionProxy,
         snapshotReader: @escaping @MainActor () -> SuggestionSnapshot,
         freshSnapshotReader: @escaping @MainActor () -> SuggestionSnapshot,
         suggestionsEnabled: @escaping @MainActor () -> Bool) {
        self.proxy = proxy
        self.snapshotReader = snapshotReader
        self.freshSnapshotReader = freshSnapshotReader
        self.suggestionsEnabled = suggestionsEnabled
    }

    func offer(hasFullAccess: Bool) {
        syncDocument()
        guard allowed(hasFullAccess: hasFullAccess), let document else {
            pendingToken = nil
            offeredRevision = nil
            offeredEntries = nil
            state = .idle
            return
        }
        if dismissedDocuments.contains(document) {
            state = .dismissed
            return
        }
        guard state != .inserted else { return }
        if case .confirming = state { return }
        let snapshot = snapshotReader()
        if let entry = snapshot.entries.first {
            offeredRevision = snapshot.revision
            offeredEntries = snapshot.entries
            state = .offered(entry)
        } else {
            offeredRevision = nil
            offeredEntries = nil
            state = .idle
        }
    }

    @discardableResult
    func beginConfirmation(hasFullAccess: Bool) -> SuggestionConfirmToken? {
        syncDocument()
        guard allowed(hasFullAccess: hasFullAccess), let document,
              !dismissedDocuments.contains(document),
              case .offered(let entry) = state, let offeredRevision else {
            pendingToken = nil
            state = .idle
            return nil
        }
        let token = SuggestionConfirmToken(documentIdentifier: document, key: entry.key,
                                           factLSN: entry.factLSN,
                                           revision: offeredRevision, nonce: UUID())
        pendingToken = token
        state = .confirming(entry)
        return token
    }

    @discardableResult
    func confirm(_ token: SuggestionConfirmToken, hasFullAccess: Bool) -> Bool {
        syncDocument()
        guard state != .inserted else { return false }
        defer { pendingToken = nil }
        guard allowed(hasFullAccess: hasFullAccess), pendingToken == token,
              document == token.documentIdentifier,
              case .confirming(let offered) = state,
              offered.key == token.key, offered.factLSN == token.factLSN else {
            state = .idle
            return false
        }
        // Never trust the value held by the UI. A forget, rewrite or republish invalidates it.
        let snapshot = freshSnapshotReader()
        guard snapshot.revision == token.revision,
              snapshot.entries == offeredEntries,
              let current = snapshot.entries.first(where: { $0.key == token.key }),
              current.factLSN == token.factLSN, current.value == offered.value else {
            state = .idle
            return false
        }
        proxy.insertText(current.value)
        state = .inserted
        return true
    }

    func dismiss() {
        syncDocument()
        if let document { dismissedDocuments.insert(document) }
        pendingToken = nil
        offeredRevision = nil
        offeredEntries = nil
        state = .dismissed
    }

    private func allowed(hasFullAccess: Bool) -> Bool {
        hasFullAccess && proxy.documentIdentifier != nil && !proxy.isSecureTextEntry
            && !proxy.fieldKind.isSensitive && suggestionsEnabled()
    }

    private func syncDocument() {
        let current = proxy.documentIdentifier
        if current != document {
            document = current
            pendingToken = nil
            offeredRevision = nil
            offeredEntries = nil
            state = .idle
        }
    }
}
