import Foundation
import PikoKit

/// Local index. SQLite with FTS5.
///
/// Retrieval, never a growing prompt — the on-device context window is 8,192 tokens and months
/// of sessions will not fit. `nearestEdits` is what makes Piko sound more like the user over
/// time: the closest past corrections become few-shot examples for the next rewrite.
public actor SQLiteMemory: Memory {
    public init(path: URL) { /* TODO */ }

    public func record(_ result: CaptureResult) async {}
    public func recordEdit(_ pair: EditPair) async {}
    public func lexicon(limit: Int) async -> [String] { [] }
    public func nearestEdits(to text: String, limit: Int) async -> [EditPair] { [] }
    public func search(_ query: String, limit: Int) async -> [CaptureResult] { [] }
}

/// In-memory implementation for tests and previews.
public actor EphemeralMemory: Memory {
    private var results: [CaptureResult] = []
    private var edits: [EditPair] = []
    public init() {}

    public func record(_ result: CaptureResult) { results.append(result) }
    public func recordEdit(_ pair: EditPair) { edits.append(pair) }
    public func lexicon(limit: Int) -> [String] { [] }
    public func nearestEdits(to text: String, limit: Int) -> [EditPair] { Array(edits.suffix(limit)) }
    public func search(_ query: String, limit: Int) -> [CaptureResult] {
        results.filter { $0.shipped.localizedCaseInsensitiveContains(query) }.suffix(limit).reversed()
    }
}
