import Foundation
import Testing
@testable import OjoApp

private func date(_ y: Int, _ m: Int, _ d: Int, _ hour: Int, _ minute: Int = 0, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
}

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

// 2026-10-05 is a Monday; 2026-10-10 a Saturday; 2026-10-11 a Sunday.

@Test func scheduleRunsWeekdaysEightToSix() {
    let policy = ScheduledPreparePolicy()
    let c = utc
    #expect(policy.isWorkTime(date(2026, 10, 5, 8, 0, calendar: c), calendar: c))
    #expect(policy.isWorkTime(date(2026, 10, 5, 17, 59, calendar: c), calendar: c))
    #expect(policy.isWorkTime(date(2026, 10, 9, 12, 30, calendar: c), calendar: c))      // Friday
    #expect(!policy.isWorkTime(date(2026, 10, 5, 7, 59, calendar: c), calendar: c))
    #expect(!policy.isWorkTime(date(2026, 10, 5, 18, 0, calendar: c), calendar: c))
    #expect(!policy.isWorkTime(date(2026, 10, 10, 12, 0, calendar: c), calendar: c))     // Saturday
    #expect(!policy.isWorkTime(date(2026, 10, 11, 12, 0, calendar: c), calendar: c))     // Sunday
}

@Test func intervalIsThirtyMinutesUnlessVerificationOverrideIsSet() {
    let suite = UserDefaults(suiteName: "ojo-test-\(UUID().uuidString)")!
    #expect(ScheduledPreparePolicy.current(defaults: suite).intervalSeconds == 1800)
    suite.set(10, forKey: "scheduledPrepareIntervalSeconds")        // below the floor: ignored
    #expect(ScheduledPreparePolicy.current(defaults: suite).intervalSeconds == 1800)
    suite.set(45, forKey: "scheduledPrepareIntervalSeconds")
    let fast = ScheduledPreparePolicy.current(defaults: suite)
    #expect(fast.intervalSeconds == 45 && fast.initialDelaySeconds == 45)
}

@Test func twoCorrectionsInARowPauseTheSchedule() {
    var guardrail = CorrectionLoopGuard()
    #expect(guardrail.record(.corrected) == false)
    #expect(guardrail.record(.corrected) == true)
}

@Test func aGoodCheckBetweenCorrectionsResetsTheCount() {
    var guardrail = CorrectionLoopGuard()
    #expect(guardrail.record(.corrected) == false)
    #expect(guardrail.record(.ok) == false)
    #expect(guardrail.record(.corrected) == false)
}

@Test func skippedAndFailedRunsNeitherCountNorReset() {
    var guardrail = CorrectionLoopGuard()
    #expect(guardrail.record(.corrected) == false)
    #expect(guardrail.record(.skipped("no face in frame")) == false)
    #expect(guardrail.record(.failed("camera busy")) == false)
    #expect(guardrail.consecutiveCorrections == 1)
    #expect(guardrail.record(.corrected) == true)
}

@Test func resetClearsTheCountWhenTheSwitchIsTurnedBackOn() {
    var guardrail = CorrectionLoopGuard()
    _ = guardrail.record(.corrected)
    _ = guardrail.record(.corrected)
    guardrail.reset()
    #expect(guardrail.record(.corrected) == false)
}

@Test func switchesDefaultOnAndRememberTheUsersChoice() {
    let suite = UserDefaults(suiteName: "ojo-test-\(UUID().uuidString)")!
    #expect(OjoPreferences.keepCameraReady(suite) == true)
    #expect(OjoPreferences.openAtLogin(suite) == true)
    suite.set(false, forKey: OjoPreferences.keepCameraReadyKey)
    suite.set(false, forKey: OjoPreferences.openAtLoginKey)
    #expect(OjoPreferences.keepCameraReady(suite) == false)
    #expect(OjoPreferences.openAtLogin(suite) == false)
}
