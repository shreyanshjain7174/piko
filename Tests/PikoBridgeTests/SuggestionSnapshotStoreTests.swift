import Foundation
import PikoBridge
import PikoKit
import Testing

@Suite struct SuggestionSnapshotStoreTests {
    private func container() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fact(_ key: String, _ value: String, lsn: Int64) -> MemoryFact {
        MemoryFact(key: key, value: value, lsn: lsn, sourceTurn: nil,
                   confidence: 1, lastUsed: .now, entityID: nil)
    }

    @Test func roundTripAndForget() throws {
        let directory = try container()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SuggestionSnapshotStore(containerURL: directory)
        let kept = fact("home", "Pune", lsn: 1)
        let forgotten = fact("usual", "flat white", lsn: 2)
        let before = SuggestionSnapshot.build(from: [kept, forgotten])
        try store.write(before)
        #expect(store.read() == before)
        let after = SuggestionSnapshot.build(from: [kept])
        try store.write(after)
        #expect(store.read() == after)
        #expect(!store.read().entries.map(\.key).contains("usual"))
    }

    @Test func missingCorruptAndUnknownVersionReadEmpty() throws {
        let directory = try container()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SuggestionSnapshotStore(containerURL: directory)
        let file = directory.appendingPathComponent(AppGroup.suggestionsFile)
        #expect(store.read() == .empty)
        try Data("{broken".utf8).write(to: file)
        #expect(store.read() == .empty)
        let snapshot = SuggestionSnapshot.build(from: [fact("home", "Pune", lsn: 1)])
        try store.write(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["version"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(store.read() == .empty)
    }

    @Test func duplicateKeysFailWholeSnapshot() throws {
        let directory = try container()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SuggestionSnapshotStore(containerURL: directory)
        let file = directory.appendingPathComponent(AppGroup.suggestionsFile)
        try store.write(SuggestionSnapshot.build(from: [fact("home", "Pune", lsn: 1)]))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var entries = try #require(object["entries"] as? [[String: Any]])
        entries.append(["key": "home", "label": "home", "value": "Mumbai", "factLSN": 2])
        object["entries"] = entries
        object["revision"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(store.read() == .empty)
    }

    @Test func lowercasePANInFileFailsWholeSnapshot() throws {
        let directory = try container()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SuggestionSnapshotStore(containerURL: directory)
        let file = directory.appendingPathComponent(AppGroup.suggestionsFile)
        try store.write(SuggestionSnapshot.build(from: [fact("home", "Pune", lsn: 1)]))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var entries = try #require(object["entries"] as? [[String: Any]])
        entries.append(["key": "hint", "label": "hint", "value": "abcde1234f", "factLSN": 2])
        object["entries"] = entries
        object["revision"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(store.read() == .empty)
    }

    @Test func dottedAadhaarInFileFailsWholeSnapshot() throws {
        let directory = try container()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SuggestionSnapshotStore(containerURL: directory)
        let file = directory.appendingPathComponent(AppGroup.suggestionsFile)
        try store.write(SuggestionSnapshot.build(from: [fact("home", "Pune", lsn: 1)]))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var entries = try #require(object["entries"] as? [[String: Any]])
        entries.append(["key": "my/id", "label": "my/id", "value": "2345.6789.0123", "factLSN": 2])
        object["entries"] = entries
        object["revision"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(store.read() == .empty)
    }

    @Test func injectedSensitiveEntryFailsWholeSnapshot() throws {
        let directory = try container()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SuggestionSnapshotStore(containerURL: directory)
        let file = directory.appendingPathComponent(AppGroup.suggestionsFile)
        try store.write(SuggestionSnapshot.build(from: [fact("home", "Pune", lsn: 1)]))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var entries = try #require(object["entries"] as? [[String: Any]])
        entries.append(["key": "hint", "label": "hint", "value": "your code is 123456", "factLSN": 2])
        object["entries"] = entries
        object["revision"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(store.read() == .empty)
    }
}
