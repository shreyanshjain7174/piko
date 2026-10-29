import Foundation
import PikoKit
import PikoMind

/// Compatibility adapter. PikoMind owns the same SQLite file; callers keep using Memory.
public actor SQLiteMemory: Memory {
    private let store: SQLiteStore

    public init(path: URL) throws {
        store = try SQLiteStore(path: path)
    }

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
    public init() {}

    public func record(_ result: CaptureResult) { results.append(result) }
    public func recordEdit(_ pair: EditPair) { edits.append(pair) }
    public func delete(_ id: UUID) { results.removeAll { $0.id == id } }
    public func lexicon(limit: Int) -> [String] { [] }
    public func nearestEdits(to text: String, limit: Int) -> [EditPair] { Array(edits.suffix(limit)) }
    public func search(_ query: String, limit: Int) -> [CaptureResult] {
        results.filter { $0.shipped.localizedCaseInsensitiveContains(query) }.suffix(limit).reversed()
    }
}

extension EphemeralMemory: ItemStore {
    public func save(_ items: [DumpItem]) { filed.append(contentsOf: items) }
    public func items(kind: DumpItem.Kind, limit: Int) -> [DumpItem] {
        Array(filed.filter { $0.kind == kind }.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
}
