import Foundation
import Testing
@testable import PikoKit

@Suite struct KeyboardPreferencesTests {
    @Test func autoListenDefaultsOnAndHonoursOptOut() throws {
        let suite = "piko.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(KeyboardPreferences.autoListen(in: defaults))
        defaults.set(false, forKey: KeyboardPreferences.autoListenKey)
        #expect(!KeyboardPreferences.autoListen(in: defaults))
        #expect(KeyboardPreferences.autoListen(in: nil))
    }
}
