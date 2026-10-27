import Foundation
import Testing
import PikoKit
@testable import PikoBridge

@Suite struct SharedContainerTests {
    @Test func ownedSubdirectoryMigratesKnownPayloadsAndExcludesThemFromBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove test storage: \(error)") }
        }
        let payload = Data("legacy draft".utf8)
        try payload.write(to: root.appendingPathComponent(AppGroup.draftFile))
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
        let directory = try SharedContainer.prepare(in: root)
        #expect(directory.lastPathComponent == "PikoShared")
        #expect(try Data(contentsOf: directory.appendingPathComponent(AppGroup.draftFile)) == payload)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(AppGroup.draftFile).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("unrelated.txt").path))
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try SharedContainer.prepare(in: root) == directory)
    }
}
