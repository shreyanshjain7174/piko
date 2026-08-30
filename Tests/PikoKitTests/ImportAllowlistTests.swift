import Testing
import Foundation

@Test("PikoKit sources import only an allowlisted set of modules")
func importAllowlist() throws {
    // Foundation is the baseline every file may import unconditionally.
    // ActivityKit is permitted only because LiveActivityAttributes.swift guards it
    // behind `#if os(iOS)` — it never actually imports on macOS/other platforms.
    let allowedImports: Set<String> = ["import Foundation", "import ActivityKit"]

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
            #expect(allowedImports.contains(trimmed),
                    "\(file.lastPathComponent): unexpected import '\(trimmed)'")
        }
    }
}
