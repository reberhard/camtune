import Foundation
import Testing
@testable import OjoApp

// 2026-11-02: the iPhone (Continuity Camera) is Ojo's primary camera (specs/ojo.md Camera Policy).

@MainActor @Test func iPhoneScenePayloadIsMarkedAndNeedsNoCalibration() async {
    let state = AppState()
    state.iPhoneCameraName = "Ryan's iPhone 16 (2025) Camera"
    var assessed: [String: Any] = [:]
    state.sceneContract = { command, payload in
        if command == "profile-select" { return ["status": "missing"] }
        if command == "assess" { assessed = payload }
        return ["state": "green", "reason": "ok", "checks": [:], "quality": [:]]
    }
    var scene = SceneMetrics(faceBox: nil, faceCount: 1)
    scene.cameraID = AppState.iPhoneCameraID
    await state.applyLivePreviewCheck(scene).value
    #expect(assessed["camera_kind"] as? String == "iphone")
    #expect(assessed["camera_validated"] as? Bool == false)
    #expect(assessed["camera_id"] as? String == "iphone:continuity")
}

@MainActor @Test func iPhoneModeNeverRunsTheTimedCameraCheck() async {
    let state = AppState()
    state.iPhoneCameraName = "Ryan's iPhone 16 (2025) Camera"
    state.keepCameraReady = true
    var calls = 0
    state.sceneContract = { _, _ in calls += 1; return [:] }
    var policy = ScheduledPreparePolicy()
    policy.startHour = 0
    policy.endHour = 24
    await state.runScheduledPrepare(policy: policy)
    #expect(calls == 0)
    #expect(state.isChecking == false)
    #expect(state.scheduledStatus == AppState.iPhoneScheduleNote)
    #expect(state.keepCameraReady == true)   // the Brio setting is kept for a fallback
}

@MainActor @Test func iPhoneModeHasNoBrioActions() {
    let state = AppState()
    state.iPhoneCameraName = "Ryan's iPhone 16 (2025) Camera"
    #expect(state.activeCameraName == "Ryan's iPhone 16 (2025) Camera")
    #expect(state.currentDevice == nil)
    #expect(state.canPrepareScene == false)
    #expect(state.canAdjustComposition == false)
    #expect(state.preparationScope == "iPhone camera")
}
