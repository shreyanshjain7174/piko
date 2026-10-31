import Foundation
import PikoKit
import Testing
@testable import PikoKeyboardCore

@MainActor
private final class SuggestionMockProxy: SuggestionProxy {
    var documentIdentifier: UUID? = UUID()
    var isSecureTextEntry = false
    var fieldKind: SuggestionFieldKind = .other
    var inserted: [String] = []
    func insertText(_ text: String) { inserted.append(text) }
}

@MainActor
private final class SuggestionFixture {
    let proxy = SuggestionMockProxy()
    var cached: SuggestionSnapshot
    var latest: SuggestionSnapshot
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    lazy var controller = SuggestionController(
        proxy: proxy,
        snapshotReader: { [unowned self] in self.cached },
        freshSnapshotReader: { [unowned self] in self.latest },
        suggestionsEnabled: { [unowned self] in
            KeyboardPreferences.suggestionsEnabled(in: self.defaults) })

    init() {
        let fact = MemoryFact(key: "favorite drink", value: "tea", lsn: 1,
                              sourceTurn: 1, confidence: 1, lastUsed: .now, entityID: nil)
        cached = SuggestionSnapshot.build(from: [fact])
        latest = cached
    }
}

@Suite("Confirmed keyboard suggestions")
@MainActor
struct SuggestionControllerTests {
    @Test func noInsertWithoutConfirm() {
        let f = SuggestionFixture()
        f.controller.offer(hasFullAccess: true)
        #expect(f.controller.offeredEntry?.value == "tea")
        #expect(f.proxy.inserted.isEmpty)
        let token = f.controller.beginConfirmation(hasFullAccess: true)
        #expect(token != nil)
        #expect(f.proxy.inserted.isEmpty)
    }

    @Test func documentSwitchBlocksInsert() throws {
        let f = SuggestionFixture()
        f.controller.offer(hasFullAccess: true)
        let token = f.controller.beginConfirmation(hasFullAccess: true)
        f.proxy.documentIdentifier = UUID()
        let confirmedToken = try #require(token)
        #expect(!f.controller.confirm(confirmedToken, hasFullAccess: true))
        #expect(f.proxy.inserted.isEmpty)
    }

    @Test func forgottenFactBlocksInsert() throws {
        let f = SuggestionFixture()
        f.controller.offer(hasFullAccess: true)
        let token = f.controller.beginConfirmation(hasFullAccess: true)
        f.latest = .empty
        let confirmedToken = try #require(token)
        #expect(!f.controller.confirm(confirmedToken, hasFullAccess: true))
        #expect(f.proxy.inserted.isEmpty)
    }

    @Test func forgettingNonNewestFactWithSameRevisionBlocksInsert() throws {
        let f = SuggestionFixture()
        let oldest = MemoryFact(key: "other", value: "Pune", lsn: 1,
                                sourceTurn: 1, confidence: 1, lastUsed: .now, entityID: nil)
        let newest = MemoryFact(key: "favorite drink", value: "tea", lsn: 2,
                                sourceTurn: 2, confidence: 1, lastUsed: .now, entityID: nil)
        f.cached = SuggestionSnapshot.build(from: [oldest, newest])
        f.latest = f.cached
        f.controller.offer(hasFullAccess: true)
        let token = f.controller.beginConfirmation(hasFullAccess: true)
        f.latest = SuggestionSnapshot.build(from: [newest])
        #expect(f.latest.revision == f.cached.revision)
        #expect(f.controller.offeredEntry == nil)
        let confirmedToken = try #require(token)
        #expect(!f.controller.confirm(confirmedToken, hasFullAccess: true))
        #expect(f.proxy.inserted.isEmpty)
    }

    @Test func revisionChangeBlocksInsert() {
        let f = SuggestionFixture()
        f.controller.offer(hasFullAccess: true)
        let token = f.controller.beginConfirmation(hasFullAccess: true)
        let fact = MemoryFact(key: "new fact", value: "new value", lsn: 2,
                              sourceTurn: 2, confidence: 1, lastUsed: .now, entityID: nil)
        f.latest = SuggestionSnapshot.build(from: [fact] + f.cached.entries.map {
            MemoryFact(key: $0.key, value: $0.value, lsn: $0.factLSN,
                       sourceTurn: $0.sourceTurn, confidence: 1, lastUsed: .now, entityID: nil)
        })
        if let token { #expect(!f.controller.confirm(token, hasFullAccess: true)) }
        #expect(f.proxy.inserted.isEmpty)
    }

    @Test func changedFactLSNBlocksInsert() {
        let f = SuggestionFixture()
        f.controller.offer(hasFullAccess: true)
        let token = f.controller.beginConfirmation(hasFullAccess: true)
        let fact = MemoryFact(key: "favorite drink", value: "tea", lsn: 2,
                              sourceTurn: 1, confidence: 1, lastUsed: .now, entityID: nil)
        f.latest = SuggestionSnapshot.build(from: [fact])
        if let token { #expect(!f.controller.confirm(token, hasFullAccess: true)) }
        #expect(f.proxy.inserted.isEmpty)
    }

    @Test func changedValueWithSameRevisionBlocksInsert() {
        let f = SuggestionFixture()
        f.controller.offer(hasFullAccess: true)
        let token = f.controller.beginConfirmation(hasFullAccess: true)
        let changed = MemoryFact(key: "favorite drink", value: "coffee", lsn: 1,
                                 sourceTurn: 1, confidence: 1, lastUsed: .now, entityID: nil)
        f.latest = SuggestionSnapshot.build(from: [changed])
        if let token { #expect(!f.controller.confirm(token, hasFullAccess: true)) }
        #expect(f.proxy.inserted.isEmpty)
    }

    @Test func tokenBindsRevisionAtOfferNotAtFirstTap() {
        let f = SuggestionFixture()
        f.controller.offer(hasFullAccess: true)
        let newer = MemoryFact(key: "new fact", value: "new value", lsn: 2,
                               sourceTurn: 2, confidence: 1, lastUsed: .now, entityID: nil)
        f.cached = SuggestionSnapshot.build(from: [newer])
        f.latest = f.cached
        let token = f.controller.beginConfirmation(hasFullAccess: true)
        if let token { #expect(!f.controller.confirm(token, hasFullAccess: true)) }
        #expect(f.proxy.inserted.isEmpty)
    }

    @Test func failClosedConditions() {
        for condition in 0..<7 {
            let f = SuggestionFixture()
            switch condition {
            case 0: f.proxy.documentIdentifier = nil
            case 1: f.proxy.isSecureTextEntry = true
            case 2: f.proxy.fieldKind = .password
            case 3: f.proxy.fieldKind = .newPassword
            case 4: f.proxy.fieldKind = .oneTimeCode
            case 5: f.proxy.fieldKind = .creditCardNumber
            default: f.defaults.set(false, forKey: KeyboardPreferences.suggestionsEnabledKey)
            }
            f.controller.offer(hasFullAccess: true)
            #expect(f.controller.offeredEntry == nil)
            #expect(f.controller.beginConfirmation(hasFullAccess: true) == nil)
            #expect(f.proxy.inserted.isEmpty)
        }
        let f = SuggestionFixture()
        f.controller.offer(hasFullAccess: false)
        #expect(f.controller.offeredEntry == nil)
        #expect(f.controller.beginConfirmation(hasFullAccess: true) == nil)
    }

    @Test func globalOffSwitchIsReadFromKeyboardPreferences() {
        let f = SuggestionFixture()
        #expect(KeyboardPreferences.suggestionsEnabled(in: f.defaults))
        f.defaults.set(false, forKey: KeyboardPreferences.suggestionsEnabledKey)
        f.controller.offer(hasFullAccess: true)
        #expect(f.controller.offeredEntry == nil)
        f.defaults.set(true, forKey: KeyboardPreferences.suggestionsEnabledKey)
        f.controller.offer(hasFullAccess: true)
        #expect(f.controller.offeredEntry != nil)
    }

    @Test func revokedAccessBlocksConfirm() {
        let f = SuggestionFixture()
        f.controller.offer(hasFullAccess: true)
        let token = f.controller.beginConfirmation(hasFullAccess: true)
        if let token { #expect(!f.controller.confirm(token, hasFullAccess: false)) }
        #expect(f.proxy.inserted.isEmpty)
    }

    @Test func conditionsRecheckedAtConfirm() {
        let f = SuggestionFixture()
        f.controller.offer(hasFullAccess: true)
        let token = f.controller.beginConfirmation(hasFullAccess: true)
        f.proxy.fieldKind = .oneTimeCode
        if let token { #expect(!f.controller.confirm(token, hasFullAccess: true)) }
        #expect(f.proxy.inserted.isEmpty)
    }

    @Test func dismissalIsSessionOnlyPerDocument() {
        let f = SuggestionFixture()
        let first = f.proxy.documentIdentifier
        f.controller.offer(hasFullAccess: true)
        f.controller.dismiss()
        f.controller.offer(hasFullAccess: true)
        #expect(f.controller.offeredEntry == nil)
        f.proxy.documentIdentifier = UUID()
        f.controller.offer(hasFullAccess: true)
        #expect(f.controller.offeredEntry != nil)
        f.proxy.documentIdentifier = first
        f.controller.offer(hasFullAccess: true)
        #expect(f.controller.offeredEntry == nil)
        let newSession = SuggestionFixture()
        newSession.proxy.documentIdentifier = first
        newSession.controller.offer(hasFullAccess: true)
        #expect(newSession.controller.offeredEntry != nil)
    }

    @Test func happyPathInsertsExactlyOnce() {
        let f = SuggestionFixture()
        f.controller.offer(hasFullAccess: true)
        let token = f.controller.beginConfirmation(hasFullAccess: true)
        let confirmed = token.map { f.controller.confirm($0, hasFullAccess: true) } ?? false
        #expect(confirmed)
        if let token { #expect(!f.controller.confirm(token, hasFullAccess: true)) }
        f.controller.offer(hasFullAccess: true)
        #expect(f.proxy.inserted == ["tea"])
        #expect(f.controller.state == .inserted)
    }
}
