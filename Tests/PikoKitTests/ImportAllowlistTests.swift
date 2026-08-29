import Testing
import Foundation

@Test("PikoKit sources import only Foundation")
func importAllowlist() throws {
    let sourcesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/PikoKit")

    let contents = try FileManager.default.contentsOfDirectory(
        at: sourcesDir, includingPropertiesForKeys: nil)
    let swiftFiles = contents.filter { $0.pathExtension == "swift" }
    #expect(!swiftFiles.isEmpty, "expected to find .swift files at \(sourcesDir.path)")

    for file in swiftFiles {
        let text = try String(contentsOf: file, encoding: .utf8)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("import ") else { continue }
            #expect(trimmed == "import Foundation",
                    "\(file.lastPathComponent): unexpected import '\(trimmed)'")
        }
    }
}
