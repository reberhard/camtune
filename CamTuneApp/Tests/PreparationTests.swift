import Foundation
import Testing
@testable import OjoApp

@MainActor private func preparedState(_ body: (AppState) async throws -> Void) async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try JSONSerialization.data(withJSONObject: [
        "camera_id": "camera:1133:2329", "call_preview_parity": true,
        "validation_receipt": "measured fixture", "stage1_accepted": true,
        "room_effects_verified": false, "responses": []
    ] as [String: Any]).write(to: file)
    let state = AppState()
    state.stage2ValidationURL = file
    state.currentDevice = CameraDevice(name: "Fixture", vendor: 1133, product: 2329, address: nil)
    state.preparationRecheck = {}
    state.cameraAccess = { true }
    try await body(state)
}

@MainActor @Test func cameraOnlyPreparationDoesNotRequireRoomMeasurements() async throws {
    try await preparedState { state in
        #expect(state.canPrepareScene)
        #expect(!state.roomPreparationAvailable)
        #expect(state.preparationScope.contains("Camera framing and exposure"))
        var commands: [String] = []
        var checks = 0
        state.error = "old error"
        state.sceneRepair = { command, payload in
            commands.append(command)
            #expect(payload["allow_room_changes"] == nil)
            return ["status": "unchanged", "reason": "framing already balanced"]
        }
        state.preparationRecheck = { checks += 1 }
        await state.meetingReadyNow()
        #expect(commands == ["camera-prepare"])
        #expect(checks == 1)
        #expect(state.error == nil)
        #expect(state.statusMessage?.contains("framing and exposure checked") == true)
        #expect(!state.isChecking)
        #expect(state.activePreparationID == nil)
    }
}

@MainActor @Test func unmeasuredRoomAndAIActionsStillFailClosed() async throws {
    try await preparedState { state in
        state.allowSceneRoomChanges = true
        #expect(!state.canPrepareScene)
        state.sceneRepair = { _, _ in Issue.record("Must not run any transaction"); return [:] }
        await state.meetingReadyNow()
        #expect(state.error?.contains("room calibration") == true)
        await state.deepRepairNow()
        #expect(state.error?.contains("room calibration") == true)
    }
}

@MainActor @Test func missingOrWrongCameraCalibrationNeverRunsPreparation() async throws {
    try await preparedState { state in
        state.currentDevice = CameraDevice(name: "Other", vendor: 1, product: 2, address: nil)
        #expect(!state.canPrepareScene)
        state.sceneRepair = { _, _ in Issue.record("Wrong camera must not run"); return [:] }
        await state.meetingReadyNow()
        #expect(state.error == "Camera framing isn't calibrated yet.")
    }
}

@MainActor @Test func improvedFramingRefreshesObservedSettingsAndRechecks() async throws {
    try await preparedState { state in
        var checked = false
        state.sceneRepair = { _, _ in
            ["status": "improved", "baseline": ["absolute_zoom": 173],
             "observed": ["absolute_zoom": 180]]
        }
        state.preparationRecheck = { checked = true }
        await state.applyFramingRecommendation()
        #expect(checked)
        #expect(state.currentSettings.intValue(for: "absolute_zoom") == 180)
        #expect(state.error == nil)
        #expect(state.statusMessage?.contains("Framing improved") == true)
    }
}

@MainActor @Test func framingFailureDoesNotClaimSuccessOrRecheck() async throws {
    try await preparedState { state in
        state.sceneRepair = { _, _ in ["status": "rollback_failed", "reason": "readback mismatch"] }
        state.preparationRecheck = { Issue.record("Failed transaction must not recheck as success") }
        await state.meetingReadyNow()
        #expect(state.error?.contains("rollback_failed") == true)
        #expect(state.statusMessage == nil)
        #expect(!state.isChecking)
    }
}

@MainActor @Test func recheckFailureIsNotCoveredByFramingSuccess() async throws {
    try await preparedState { state in
        state.sceneRepair = { _, _ in ["status": "unchanged"] }
        state.preparationRecheck = { state.error = "Check failed"; state.statusMessage = nil }
        await state.meetingReadyNow()
        #expect(state.error == "Check failed")
        #expect(state.statusMessage == nil)
    }
}

@MainActor @Test func deniedCameraPermissionDoesNotLaunchRepair() async throws {
    try await preparedState { state in
        state.cameraAccess = { false }
        state.sceneRepair = { _,_ in Issue.record("Permission denial must not launch helper"); return [:] }
        await state.meetingReadyNow()
        #expect(state.error?.contains("Camera access is off") == true)
        #expect(!state.isChecking)
    }
}

@MainActor @Test func deniedCameraPermissionDoesNotLaunchCheck() async {
    let state = AppState()
    state.cameraAccess = { false }
    await state.checkNow()
    #expect(state.error?.contains("Camera access is off") == true)
    #expect(!state.isChecking)
    #expect(state.statusMessage == nil)
}
