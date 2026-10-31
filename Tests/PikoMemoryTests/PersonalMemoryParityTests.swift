import Foundation
import Testing
import PikoKit
@testable import PikoMemory

private func assertPersonalMemoryParity(_ memory: any Memory) async throws {
    let capture = CaptureResult(raw: "Riya is my sister", shipped: "Riya is my sister")
    await memory.record(capture)
    let source = try await memory.captureTurn(forCapture: capture.id)
    #expect(source.session == capture.id && source.role == .user && source.text == capture.shipped)
    #expect(try await memory.turn(lsn: source.lsn) == source)
    #expect(try await memory.turns(in: capture.id, limit: 1) == [source])
    await #expect(throws: PersonalMemoryError.invalidLimit(0)) {
        try await memory.turns(in: capture.id, limit: 0)
    }

    let entity = MemoryEntity(
        id: "riya", name: "Riya", kind: "person",
        createdAt: Date(timeIntervalSince1970: 123), aliases: ["Ri"]
    )
    try await memory.createEntity(entity)
    #expect(try await memory.entity(id: entity.id) == entity)
    #expect(try await memory.entities(matching: "Ri", limit: 1) == [entity])
    await #expect(throws: PersonalMemoryError.entityAlreadyExists(entity.id)) {
        try await memory.createEntity(entity)
    }
    let input = MemoryFactInput(key: "owner/sister/name", value: "Riya", sourceTurn: source.lsn,
                                confidence: 0.9, entityID: entity.id)
    let first = try await memory.setFact(input, ifLSN: nil)
    #expect(try await memory.fact(forKey: input.key) == first)
    let updated = try await memory.setFact(
        MemoryFactInput(key: input.key, value: "Riya Jain", sourceTurn: source.lsn,
                        confidence: 1, entityID: entity.id),
        ifLSN: first.lsn
    )
    #expect(updated.lsn == first.lsn + 1)
    #expect(try await memory.facts(matching: "Ri", limit: 1) == [updated])
    await #expect(throws: PersonalMemoryError.factConflict(key: first.key, expectedLSN: first.lsn,
                                                            actualLSN: updated.lsn)) {
        try await memory.forgetFact(forKey: first.key, ifLSN: first.lsn)
    }
    await memory.delete(capture.id)
    #expect(try await memory.turn(lsn: source.lsn) == nil)
    #expect(try await memory.turns(in: capture.id, limit: 1).isEmpty)
    await #expect(throws: PersonalMemoryError.sourceCaptureMissing(capture.id)) {
        try await memory.captureTurn(forCapture: capture.id)
    }
    #expect(try await memory.fact(forKey: input.key)?.sourceTurn == nil)
    try await memory.forgetFact(forKey: input.key, ifLSN: updated.lsn)
    #expect(try await memory.fact(forKey: input.key) == nil)
}

@Test("Ephemeral memory implements fact, turn, entity, CAS and deletion semantics")
func ephemeralPersonalMemoryParity() async throws {
    try await assertPersonalMemoryParity(EphemeralMemory())
}

@Test("SQLite adapter implements the same fact, turn, entity, CAS and deletion semantics")
func sqlitePersonalMemoryParity() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: path) }
    try await assertPersonalMemoryParity(SQLiteMemory(path: path))
}
