import Foundation
import PikoKit

enum SharedContainer {
    static func prepare(in root: URL) throws -> URL {
        var directory = root.appendingPathComponent("PikoShared", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        for name in [AppGroup.stateFile, AppGroup.draftFile, AppGroup.resultFile,
                     AppGroup.captureRequestFile, AppGroup.audioLevelFile] {
            let old = root.appendingPathComponent(name)
            let destination = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: old.path),
                  !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try FileManager.default.moveItem(at: old, to: destination)
            } catch {
                // A second process may have completed the same migration.
                guard !FileManager.default.fileExists(atPath: old.path),
                      FileManager.default.fileExists(atPath: destination.path) else { throw error }
            }
        }
        return directory
    }
}
