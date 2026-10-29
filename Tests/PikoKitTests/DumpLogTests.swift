import Foundation
import Testing
@testable import PikoKit

@Suite struct DumpLogTests {
    @Test func countsOnlyTheLastSevenDaysAndKeepsThirtyDays() throws {
        let suite = "piko.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 86_400
        let log = DumpLog(defaults: defaults)
        for offset in [40.0, 7.5, 6.9, 1, 0] { log.record(at: now - offset * day) }
        #expect(log.countLastSevenDays(now: now) == 3)
        #expect(log.dates.count == 4)
    }
}
