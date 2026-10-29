import Testing
import Foundation
@testable import PikoMemory
import PikoKit

@Suite struct ItemStoreTests {
    private func roundTrip(_ store: some ItemStore) async {
        let older = DumpItem(kind: .journal, text: "Felt calm after yoga.", createdAt: Date(timeIntervalSince1970: 100))
        let newer = DumpItem(kind: .journal, text: "Anxious about the interview.", createdAt: Date(timeIntervalSince1970: 200))
        let note = DumpItem(kind: .note, text: "Planner app with stickers.", createdAt: Date(timeIntervalSince1970: 150))
        await store.save([older, note, newer])
        let journal = await store.items(kind: .journal, limit: 10)
        #expect(journal.map(\.id) == [newer.id, older.id])
        #expect(await store.items(kind: .note, limit: 10).map(\.text) == ["Planner app with stickers."])
        #expect(await store.items(kind: .journal, limit: 1).count == 1)
    }

    @Test func sqliteStoresNotesAndJournalNewestFirst() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        await roundTrip(try SQLiteMemory(path: url))
    }

    @Test func ephemeralStoresNotesAndJournalNewestFirst() async {
        await roundTrip(EphemeralMemory())
    }

    @Test func dueDateSurvivesSQLite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let memory = try SQLiteMemory(path: url)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        await memory.save([DumpItem(kind: .reminder, text: "Call mom", due: due)])
        let saved = await memory.items(kind: .reminder, limit: 1)
        #expect(saved.first?.due == due)
    }
}
