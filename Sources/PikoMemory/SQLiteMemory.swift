import Foundation
import PikoKit
import PikoMind

/// Compatibility adapter. PikoMind owns the same SQLite file; callers keep using Memory.
public actor SQLiteMemory: Memory {
    private let store: SQLiteStore

    public init(path: URL) throws {
        store = try SQLiteStore(path: path)
    }

    #if DEBUG
    public static func reconcileDevelopmentHistory(path: URL) throws -> DevelopmentHistoryRecovery.Outcome {
        try DevelopmentHistoryRecovery.reconcile(path: path)
    }
    #endif

    public func record(_ result: CaptureResult) async { await store.record(result) }
    public func recordEdit(_ pair: EditPair) async { await store.recordEdit(pair) }
    public func delete(_ id: UUID) async { await store.delete(id) }
    public func lexicon(limit: Int) async -> [String] { await store.lexicon(limit: limit) }
    public func nearestEdits(to text: String, limit: Int) async -> [EditPair] {
        await store.nearestEdits(to: text, limit: limit)
    }
    public func search(_ query: String, limit: Int) async -> [CaptureResult] {
        await store.search(query, limit: limit)
    }
    public func appendTurn(session: UUID, role: MemoryTurn.Role, text: String, at: Date) async throws -> MemoryTurn {
        try await store.appendTurn(session: session, role: role, text: text, at: at)
    }
    public func captureTurn(forCapture id: UUID) async throws -> MemoryTurn {
        try await store.captureTurn(forCapture: id)
    }
    public func turn(lsn: Int64) async throws -> MemoryTurn? { try await store.turn(lsn: lsn) }
    public func turns(in session: UUID, limit: Int) async throws -> [MemoryTurn] {
        try await store.turns(in: session, limit: limit)
    }
    public func setFact(_ input: MemoryFactInput, ifLSN: Int64?) async throws -> MemoryFact {
        try await store.setFact(input, ifLSN: ifLSN)
    }
    public func fact(forKey key: String) async throws -> MemoryFact? { try await store.fact(forKey: key) }
    public func facts(matching query: String?, limit: Int) async throws -> [MemoryFact] {
        try await store.facts(matching: query, limit: limit)
    }
    public func touchFact(forKey key: String, ifLSN: Int64, at: Date) async throws -> MemoryFact {
        try await store.touchFact(forKey: key, ifLSN: ifLSN, at: at)
    }
    public func forgetFact(forKey key: String, ifLSN: Int64) async throws {
        try await store.forgetFact(forKey: key, ifLSN: ifLSN)
    }
    public func createEntity(_ entity: MemoryEntity) async throws { try await store.createEntity(entity) }
    public func entity(id: String) async throws -> MemoryEntity? { try await store.entity(id: id) }
    public func entities(matching query: String?, limit: Int) async throws -> [MemoryEntity] {
        try await store.entities(matching: query, limit: limit)
    }
    public func forgetEntity(id: String) async throws { try await store.forgetEntity(id: id) }
}

extension SQLiteMemory: ItemStore {
    public func save(_ items: [DumpItem]) async { await store.save(items) }
    public func items(kind: DumpItem.Kind, limit: Int) async -> [DumpItem] {
        await store.items(kind: kind, limit: limit)
    }
}

/// In-memory implementation for tests and previews.
public actor EphemeralMemory: Memory {
    private var results: [CaptureResult] = []
    private var edits: [EditPair] = []
    private var filed: [DumpItem] = []
    private var turns: [Int64: MemoryTurn] = [:]
    private var nextTurnLSN: Int64 = 1
    private var savedFacts: [String: MemoryFact] = [:]
    private var savedEntities: [String: MemoryEntity] = [:]
    public init() {}

    public func record(_ result: CaptureResult) {
        results.append(result)
        // The SQLite results trigger inserts exactly one shipped/user turn.
        turns[nextTurnLSN] = MemoryTurn(
            lsn: nextTurnLSN, session: result.id, role: .user, text: result.shipped, at: result.createdAt
        )
        nextTurnLSN += 1
    }
    public func recordEdit(_ pair: EditPair) { edits.append(pair) }
    public func delete(_ id: UUID) {
        results.removeAll { $0.id == id }
        let removed = Set(turns.values.filter { $0.session == id }.map(\.lsn))
        turns = turns.filter { !removed.contains($0.key) }
        for (key, fact) in savedFacts where fact.sourceTurn.map(removed.contains) == true {
            savedFacts[key] = MemoryFact(
                key: fact.key, value: fact.value, lsn: fact.lsn, sourceTurn: nil,
                confidence: fact.confidence, lastUsed: fact.lastUsed, entityID: fact.entityID
            )
        }
    }
    public func lexicon(limit: Int) -> [String] { [] }
    public func nearestEdits(to text: String, limit: Int) -> [EditPair] { Array(edits.suffix(limit)) }
    public func search(_ query: String, limit: Int) -> [CaptureResult] {
        results.filter { $0.shipped.localizedCaseInsensitiveContains(query) }.suffix(limit).reversed()
    }

    public func appendTurn(session: UUID, role: MemoryTurn.Role, text: String, at: Date) throws -> MemoryTurn {
        try MemoryTurn.validate(text: text, at: at)
        let turn = MemoryTurn(lsn: nextTurnLSN, session: session, role: role, text: text, at: at)
        turns[nextTurnLSN] = turn
        nextTurnLSN += 1
        return turn
    }

    public func captureTurn(forCapture id: UUID) throws -> MemoryTurn {
        guard let capture = results.first(where: { $0.id == id }),
              let source = turns.values.filter({ $0.session == id && $0.role == .user
                                                  && $0.text == capture.shipped && $0.at == capture.createdAt })
                .min(by: { $0.lsn < $1.lsn }) else {
            throw PersonalMemoryError.sourceCaptureMissing(id)
        }
        return source
    }

    public func turn(lsn: Int64) throws -> MemoryTurn? {
        guard lsn > 0 else { throw PersonalMemoryError.invalidSourceTurn(lsn) }
        return turns[lsn]
    }

    public func turns(in session: UUID, limit: Int) throws -> [MemoryTurn] {
        _ = try PersonalMemoryQuery.validated(nil, limit: limit)
        return Array(turns.values.filter { $0.session == session }.sorted { $0.lsn > $1.lsn }.prefix(limit))
    }

    public func setFact(_ input: MemoryFactInput, ifLSN expected: Int64?) throws -> MemoryFact {
        try input.validate()
        try validateExpectedLSN(expected)
        guard let source = turns[input.sourceTurn] else {
            throw PersonalMemoryError.sourceTurnMissing(input.sourceTurn)
        }
        guard source.role == .user else { throw PersonalMemoryError.sourceTurnNotUser(input.sourceTurn) }
        if let entityID = input.entityID, savedEntities[entityID] == nil {
            throw PersonalMemoryError.entityMissing(entityID)
        }
        let prior = savedFacts[input.key]
        guard prior?.lsn == expected else {
            throw PersonalMemoryError.factConflict(
                key: input.key, expectedLSN: expected, actualLSN: prior?.lsn
            )
        }
        if expected == Int64.max { throw PersonalMemoryError.revisionExhausted }
        let fact = MemoryFact(
            key: input.key, value: input.value, lsn: (expected ?? 0) + 1,
            sourceTurn: input.sourceTurn, confidence: input.confidence,
            lastUsed: max(prior?.lastUsed ?? input.lastUsed, input.lastUsed), entityID: input.entityID
        )
        savedFacts[fact.key] = fact
        return fact
    }

    public func fact(forKey key: String) throws -> MemoryFact? {
        try MemoryFact.validateKey(key)
        return savedFacts[key]
    }

    public func facts(matching query: String?, limit: Int) throws -> [MemoryFact] {
        let query = try PersonalMemoryQuery.validated(query, limit: limit)
        return Array(savedFacts.values.filter { fact in
            guard let query else { return true }
            return fact.key.range(of: query, options: .caseInsensitive) != nil
                || fact.value.range(of: query, options: .caseInsensitive) != nil
                || fact.entityID.flatMap({ savedEntities[$0] }).map { entity in
                    entity.name.range(of: query, options: .caseInsensitive) != nil
                        || entity.aliases.contains { $0.range(of: query, options: .caseInsensitive) != nil }
                } == true
        }.sorted { $0.lastUsed == $1.lastUsed ? $0.key < $1.key : $0.lastUsed > $1.lastUsed }
            .prefix(limit))
    }

    public func touchFact(forKey key: String, ifLSN expected: Int64, at: Date) throws -> MemoryFact {
        try MemoryFact.validateKey(key)
        try validateExpectedLSN(expected)
        guard at.timeIntervalSince1970.isFinite else { throw PersonalMemoryError.invalidTimestamp }
        if expected == Int64.max { throw PersonalMemoryError.revisionExhausted }
        guard let prior = savedFacts[key], prior.lsn == expected else {
            throw PersonalMemoryError.factConflict(
                key: key, expectedLSN: expected, actualLSN: savedFacts[key]?.lsn
            )
        }
        let touched = MemoryFact(
            key: key, value: prior.value, lsn: expected + 1, sourceTurn: prior.sourceTurn,
            confidence: prior.confidence, lastUsed: max(prior.lastUsed, at), entityID: prior.entityID
        )
        savedFacts[key] = touched
        return touched
    }

    public func forgetFact(forKey key: String, ifLSN expected: Int64) throws {
        try MemoryFact.validateKey(key)
        try validateExpectedLSN(expected)
        guard savedFacts[key]?.lsn == expected else {
            throw PersonalMemoryError.factConflict(
                key: key, expectedLSN: expected, actualLSN: savedFacts[key]?.lsn
            )
        }
        savedFacts.removeValue(forKey: key)
    }

    public func createEntity(_ entity: MemoryEntity) throws {
        try entity.validate()
        guard savedEntities[entity.id] == nil else {
            throw PersonalMemoryError.entityAlreadyExists(entity.id)
        }
        savedEntities[entity.id] = entity
    }

    public func entity(id: String) throws -> MemoryEntity? {
        try MemoryEntity.validateID(id)
        return savedEntities[id]
    }

    public func entities(matching query: String?, limit: Int) throws -> [MemoryEntity] {
        let query = try PersonalMemoryQuery.validated(query, limit: limit)
        return Array(savedEntities.values.filter { entity in
            guard let query else { return true }
            return entity.name.range(of: query, options: .caseInsensitive) != nil
                || entity.kind.range(of: query, options: .caseInsensitive) != nil
                || entity.aliases.contains { $0.range(of: query, options: .caseInsensitive) != nil }
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }.prefix(limit))
    }

    public func forgetEntity(id: String) throws {
        try MemoryEntity.validateID(id)
        if savedFacts.values.contains(where: { $0.entityID == id && $0.lsn == Int64.max }) {
            throw PersonalMemoryError.revisionExhausted
        }
        guard savedEntities.removeValue(forKey: id) != nil else {
            throw PersonalMemoryError.entityMissing(id)
        }
        for (key, fact) in savedFacts where fact.entityID == id {
            savedFacts[key] = MemoryFact(
                key: fact.key, value: fact.value, lsn: fact.lsn + 1, sourceTurn: fact.sourceTurn,
                confidence: fact.confidence, lastUsed: fact.lastUsed, entityID: nil
            )
        }
    }

    private func validateExpectedLSN(_ expected: Int64?) throws {
        if let expected, expected < 0 { throw PersonalMemoryError.invalidExpectedLSN(expected) }
    }
}

extension EphemeralMemory: ItemStore {
    public func save(_ items: [DumpItem]) { filed.append(contentsOf: items) }
    public func items(kind: DumpItem.Kind, limit: Int) -> [DumpItem] {
        Array(filed.filter { $0.kind == kind }.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
}
