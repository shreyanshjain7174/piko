import Foundation
import Testing
@testable import PikoBrain

@Suite struct SpokenTimeTests {
    /// Wed 21 Oct 2026, 21:52 local time — the moment the user hit the noon bug.
    private let now: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 21
        components.hour = 21; components.minute = 52
        return Calendar.current.date(from: components)!
    }()
    private let calendar = Calendar.current

    private func hm(_ when: SpokenWhen?) -> String? {
        guard let when, when.hasTime else { return nil }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: when.date)
        return "\(parts.weekday!)-\(parts.hour!):\(String(format: "%02d", parts.minute!))"
    }

    @Test func dateOnlyPhraseBorrowsTheTimeSpokenNextToIt() {
        let when = SpokenDate.resolve("Friday", context: "put dentist on my calendar on Friday at four", now: now)
        #expect(hm(when) == "6-16:00")
    }

    @Test func dateOnlyWithNoTimeAnywhereIsMarkedUnknown() {
        let when = SpokenDate.resolve("Friday", context: "put dentist on my calendar on Friday", now: now)
        #expect(when?.hasTime == false)
        #expect(calendar.component(.weekday, from: when!.date) == 6)
    }

    @Test func spokenTimesWithoutMeridiemPreferDaytime() {
        #expect(hm(SpokenDate.resolve("at 4", context: "", now: now)) == "5-16:00")
        #expect(hm(SpokenDate.resolve("at four", context: "", now: now)) == "5-16:00")
        #expect(hm(SpokenDate.resolve("4 o'clock", context: "", now: now)) == "5-16:00")
        #expect(hm(SpokenDate.resolve("at 10:30", context: "", now: now)) == "5-10:30")
    }

    @Test func pastTimeWithoutADayRollsToTomorrow() {
        #expect(hm(SpokenDate.resolve("4 PM", context: "", now: now)) == "5-16:00")
        #expect(hm(SpokenDate.resolve("11 pm", context: "", now: now)) == "4-23:00")
    }

    @Test func explicitDateAndTimeIsKept() {
        #expect(hm(SpokenDate.resolve("Friday at 4 p.m.", context: "", now: now)) == "6-16:00")
        #expect(hm(SpokenDate.resolve("tomorrow at 6", context: "", now: now)) == "5-18:00")
        #expect(hm(SpokenDate.resolve("Sunday morning", context: "", now: now)) == "1-9:00")
    }

    @Test func selfCorrectionUsesTheLastTime() {
        #expect(hm(SpokenDate.resolve("at 3, no actually 5 pm", context: "", now: now)) == "5-17:00")
    }

    @Test func nothingTimeLikeIsNil() {
        #expect(SpokenDate.resolve("oat milk", context: "", now: now) == nil)
        #expect(SpokenDate.resolve("in 4 items", context: "", now: now) == nil)
    }
}
