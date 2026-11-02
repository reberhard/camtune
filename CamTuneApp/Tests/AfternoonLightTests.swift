import Foundation
import Testing
@testable import OjoApp

@Test func afternoonLightDefaultsToTheCapturedPositions() {
    let defaults = UserDefaults(suiteName: "afternoon-light-test-\(UUID())")!
    let saved = AfternoonLight.positions(defaults)
    #expect(saved.left == 24 && saved.right == 34)
}

@Test func afternoonLightSaveOverridesAndClamps() {
    let defaults = UserDefaults(suiteName: "afternoon-light-test-\(UUID())")!
    AfternoonLight.save(left: 40, right: 120, defaults)
    let saved = AfternoonLight.positions(defaults)
    #expect(saved.left == 40 && saved.right == 100)
}

@Test func afternoonLightMatchesWithinMotorTolerance() {
    let saved = (left: 24, right: 34)
    #expect(AfternoonLight.matches(left: 25, right: 31, saved))
    #expect(!AfternoonLight.matches(left: 50, right: 50, saved))
    #expect(!AfternoonLight.matches(left: nil, right: 34, saved))
}
