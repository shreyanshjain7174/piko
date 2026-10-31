import Foundation
import PikoBridge
import PikoKit
import PikoMemory

/// The sole app-side publisher of keyboard suggestions. Fact writes succeed even if publishing fails.
actor PublishingMemory: Memory {
    typealias Writer = @Sendable (SuggestionSnapshot) throws -> Void
    private let underlying: SQLiteMemory
    private let writer: Writer
    private let snapshotStore: SuggestionSnapshotStore
    private var recentFacts: [String: MemoryFact] = [:]
    private var tail: Task<Void, Never>?
    private(set) var publishError: String?
    private var onPublishFailure: @Sendable (String) -> Void

    init(_ underlying: SQLiteMemory, suggestionsContainer: URL? = nil,
         writer: Writer? = nil, onPublishFailure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.underlying = underlying
        let store: SuggestionSnapshotStore
        if let suggestionsContainer { store = SuggestionSnapshotStore(containerURL: suggestionsContainer) }
        else {
            guard let sharedStore = SuggestionSnapshotStore() else { throw PikoError.sharedContainerUnavailable }
            store = sharedStore
        }
        snapshotStore = store
        self.writer = writer ?? { try store.write($0) }
        self.onPublishFailure = onPublishFailure
    }

    #if DEBUG
    func snapshotCount() -> Int { snapshotStore.read().entries.count }
    #endif

    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) { onPublishFailure = handler }

    func republish() async { await publish() }

    private func publish() async {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            await writeSnapshot()
        }
        tail = task
        await task.value
    }

    private func writeSnapshot() async {
        do {
            let facts = try await underlying.facts(matching: nil, limit: 100)
            // SQLite lists by lastUsed, not fact LSN. Keep the most recent writes even
            // when their lastUsed date falls outside that 100-row window. On relaunch,
            // validate the previous snapshot against live facts before reusing its keys.
            let candidates = Set(recentFacts.keys).union(snapshotStore.read().entries.map(\.key))
            var byKey = Dictionary(uniqueKeysWithValues: facts.map { ($0.key, $0) })
            for key in candidates where byKey[key] == nil {
                if let current = try await underlying.fact(forKey: key) { byKey[key] = current }
            }
            try writer(SuggestionSnapshot.build(from: Array(byKey.values)))
            publishError = nil
        } catch {
            let message = "Piko saved your fact, but could not update keyboard suggestions. Reopen Piko to retry."
            publishError = message
            do { try writer(.empty) } catch { print("Piko suggestions fail-closed write failed: \(error)") }
            onPublishFailure(message)
        }
    }

    private func rememberRecent(_ fact: MemoryFact) {
        recentFacts[fact.key] = fact
        if recentFacts.count > 50,
           let oldest = recentFacts.values.min(by: { $0.lsn < $1.lsn }) {
            recentFacts.removeValue(forKey: oldest.key)
        }
    }

    func record(_ result: CaptureResult) async { await underlying.record(result) }
    func recordEdit(_ pair: EditPair) async { await underlying.recordEdit(pair) }
    func lexicon(limit: Int) async -> [String] { await underlying.lexicon(limit: limit) }
    func nearestEdits(to text: String, limit: Int) async -> [EditPair] { await underlying.nearestEdits(to: text, limit: limit) }
    func search(_ query: String, limit: Int) async -> [CaptureResult] { await underlying.search(query, limit: limit) }
    func delete(_ id: UUID) async { await underlying.delete(id) }
    func appendTurn(session: UUID, role: MemoryTurn.Role, text: String, at: Date) async throws -> MemoryTurn {
        try await underlying.appendTurn(session: session, role: role, text: text, at: at)
    }
    func captureTurn(forCapture id: UUID) async throws -> MemoryTurn { try await underlying.captureTurn(forCapture: id) }
    func turn(lsn: Int64) async throws -> MemoryTurn? { try await underlying.turn(lsn: lsn) }
    func turns(in session: UUID, limit: Int) async throws -> [MemoryTurn] { try await underlying.turns(in: session, limit: limit) }
    func setFact(_ input: MemoryFactInput, ifLSN: Int64?) async throws -> MemoryFact {
        let fact = try await underlying.setFact(input, ifLSN: ifLSN)
        rememberRecent(fact)
        await publish()
        return fact
    }
    func fact(forKey key: String) async throws -> MemoryFact? { try await underlying.fact(forKey: key) }
    func facts(matching query: String?, limit: Int) async throws -> [MemoryFact] {
        try await underlying.facts(matching: query, limit: limit)
    }
    func touchFact(forKey key: String, ifLSN: Int64, at: Date) async throws -> MemoryFact {
        let fact = try await underlying.touchFact(forKey: key, ifLSN: ifLSN, at: at)
        rememberRecent(fact)
        await publish()
        return fact
    }
    func forgetFact(forKey key: String, ifLSN: Int64) async throws {
        try await underlying.forgetFact(forKey: key, ifLSN: ifLSN)
        recentFacts.removeValue(forKey: key)
        await publish()
    }
    func createEntity(_ entity: MemoryEntity) async throws { try await underlying.createEntity(entity) }
    func entity(id: String) async throws -> MemoryEntity? { try await underlying.entity(id: id) }
    func entities(matching query: String?, limit: Int) async throws -> [MemoryEntity] {
        try await underlying.entities(matching: query, limit: limit)
    }
    func forgetEntity(id: String) async throws {
        try await underlying.forgetEntity(id: id)
        await publish()
    }
}
