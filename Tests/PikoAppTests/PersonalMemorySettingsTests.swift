import Foundation
import PikoKit
import PikoMemory
import SQLite3
import Testing
@testable import Piko

#if DEBUG
private enum SettingsFixtureError: Error { case sqlite }

private func settingsFixturePath() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("piko-settings-\(UUID().uuidString).sqlite")
}

private func removeSettingsFixture(_ path: URL) {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path.path + suffix)
    }
}

private func breakSettingsFixture(_ path: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          let handle else {
        sqlite3_close(handle)
        throw SettingsFixtureError.sqlite
    }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, "DROP TABLE facts", nil, nil, nil) == SQLITE_OK else {
        throw SettingsFixtureError.sqlite
    }
}

@Suite("Native saved-fact settings with isolated SQLite", .serialized)
@MainActor
struct PersonalMemorySettingsTests {
    private func save(_ memory: any Memory, key: String, value: String,
                      ifLSN: Int64? = nil) async throws -> MemoryFact {
        let turn = try await memory.appendTurn(session: UUID(), role: .user,
                                               text: "Remember \(key) is \(value)", at: .now)
        return try await memory.setFact(
            MemoryFactInput(key: key, value: value, sourceTurn: turn.lsn, confidence: 1),
            ifLSN: ifLSN
        )
    }

    @Test("Only actual saved facts appear; missing provenance is not described as a citation")
    func readsSavedFactsAndSourceAvailability() async throws {
        let path = settingsFixturePath()
        defer { removeSettingsFixture(path) }
        let memory = try SQLiteMemory(path: path)
        let model = PersonalMemorySettingsModel(memory: memory)
        await model.load()
        #expect(model.facts.isEmpty && model.hasLoaded && model.errorMessage == nil)

        let capture = CaptureResult(raw: "Remember my sister is Riya",
                                    shipped: "Remember my sister is Riya")
        await memory.record(capture)
        let turn = try await memory.captureTurn(forCapture: capture.id)
        let saved = try await memory.setFact(
            MemoryFactInput(key: "my/sister", value: "Riya",
                            sourceTurn: turn.lsn, confidence: 1), ifLSN: nil
        )
        await model.load()
        #expect(model.facts == [saved])
        #expect(model.sourceDescription(for: saved) == "Source: \(turn.text)")

        await memory.delete(capture.id)
        await model.load()
        let retained = try #require(model.facts.first)
        #expect(retained.value == "Riya" && retained.sourceTurn == nil)
        #expect(model.sourceDescription(for: retained) == "Original source is no longer available.")
    }

    @Test("The 100-result bound is visible and a specific search can find a later fact")
    func boundedSearch() async throws {
        let path = settingsFixturePath()
        defer { removeSettingsFixture(path) }
        let memory = try SQLiteMemory(path: path)
        let model = PersonalMemorySettingsModel(memory: memory)
        let source = try await memory.appendTurn(session: UUID(), role: .user,
                                                 text: "Synthetic saved settings fixtures", at: .now)
        for index in 0...100 {
            let key = String(format: "my/fact-%03d", index)
            _ = try await memory.setFact(
                MemoryFactInput(key: key, value: "value \(index)",
                                sourceTurn: source.lsn, confidence: 1), ifLSN: nil
            )
        }
        await model.load()
        #expect(model.facts.count == 100 && model.reachedLimit)
        #expect(model.limitMessage.contains("More may match"))
        #expect(!model.facts.contains(where: { $0.key == "my/fact-100" }))

        model.query = "fact-100"
        await model.load()
        #expect(model.facts.map(\.key) == ["my/fact-100"])
        #expect(!model.reachedLimit && model.limitMessage.contains("up to 100"))
    }

    @Test("Cancel and absence of confirmation do not delete; confirmed forget removes only selected key")
    func forgetRequiresConfirmation() async throws {
        let path = settingsFixturePath()
        defer { removeSettingsFixture(path) }
        let memory = try SQLiteMemory(path: path)
        let city = try await save(memory, key: "my/city", value: "Pune")
        let sister = try await save(memory, key: "my/sister", value: "Riya")
        let model = PersonalMemorySettingsModel(memory: memory)
        await model.load()
        await model.confirmForget()
        #expect(try await memory.fact(forKey: sister.key) == sister)

        model.selectForForget(sister)
        #expect(model.pendingFact == sister)
        model.cancelForget()
        await model.confirmForget()
        #expect(try await memory.fact(forKey: sister.key) == sister)

        model.selectForForget(sister)
        await model.confirmForget()
        #expect(try await memory.fact(forKey: sister.key) == nil)
        #expect(try await memory.fact(forKey: city.key) == city)
        #expect(model.facts == [city] && model.errorMessage == nil && !model.isForgetting)
    }

    @Test("A saved fact changed after selection is not deleted without a fresh review")
    func staleUpdateNeedsNewConfirmation() async throws {
        let path = settingsFixturePath()
        defer { removeSettingsFixture(path) }
        let memory = try SQLiteMemory(path: path)
        let original = try await save(memory, key: "my/city", value: "Pune")
        let model = PersonalMemorySettingsModel(memory: memory)
        await model.load()
        model.selectForForget(original)
        let updated = try await save(memory, key: original.key, value: "Goa", ifLSN: original.lsn)
        await model.confirmForget()
        #expect(try await memory.fact(forKey: original.key) == updated)
        #expect(model.errorMessage?.contains("changed") == true)
        #expect(!model.isForgetting && model.facts.isEmpty)

        await model.load()
        model.selectForForget(try #require(model.facts.first))
        await model.confirmForget()
        #expect(try await memory.fact(forKey: original.key) == nil)
    }

    @Test("Deleting and recreating the same key cannot satisfy an old approval")
    func staleDeleteRecreateNeedsNewConfirmation() async throws {
        let path = settingsFixturePath()
        defer { removeSettingsFixture(path) }
        let memory = try SQLiteMemory(path: path)
        let original = try await save(memory, key: "my/city", value: "Pune")
        let model = PersonalMemorySettingsModel(memory: memory)
        await model.load()
        model.selectForForget(original)
        try await memory.forgetFact(forKey: original.key, ifLSN: original.lsn)
        let recreated = try await save(memory, key: original.key, value: "Goa")
        #expect(recreated.lsn != original.lsn)
        await model.confirmForget()
        #expect(try await memory.fact(forKey: original.key) == recreated)
        #expect(model.errorMessage?.contains("changed") == true)
        #expect(!model.isForgetting)
    }

    @Test("A real SQLite read error is visible and ends loading rather than showing an empty success")
    func readErrorIsVisible() async throws {
        let path = settingsFixturePath()
        defer { removeSettingsFixture(path) }
        let memory = try SQLiteMemory(path: path)
        let model = PersonalMemorySettingsModel(memory: memory)
        try breakSettingsFixture(path)
        await model.load()
        #expect(model.errorMessage?.contains("could not read") == true)
        #expect(model.facts.isEmpty && model.hasLoaded && !model.isLoading)
    }
}
#endif
