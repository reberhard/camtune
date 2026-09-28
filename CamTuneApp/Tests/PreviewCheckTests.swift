import Foundation
import Testing
@testable import OjoApp

@MainActor @Test func previewRefreshDoesNotInventManualCheckEvents() async {
    let state = AppState()
    var triggers: [String] = []
    var assessments = 0
    state.sceneContract = { command, payload in
        if command == "profile-select" { return ["status": "missing"] }
        if command == "log-event" {
            triggers.append(payload["trigger"] as? String ?? "missing")
            return [:]
        }
        assessments += 1
        return ["state": "unknown", "reason": "test", "checks": [:], "quality": [:]]
    }
    let scene = SceneMetrics(faceBox: nil, faceCount: 0)
    for _ in 0..<5 { await state.applyLivePreviewCheck(scene).value }
    #expect(assessments == 5)
    #expect(triggers.isEmpty)
    await state.applyLivePreviewCheck(scene, logTrigger: "manual").value
    await state.applyLivePreviewCheck(scene, logTrigger: "auto").value
    #expect(triggers == ["manual", "auto"])
}

@MainActor @Test func eventWriteFailureIsVisibleWithoutLosingAssessment() async {
    let state = AppState()
    state.sceneContract = { command, _ in
        if command == "profile-select" { return ["status": "missing"] }
        if command == "log-event" { throw CocoaError(.fileWriteOutOfSpace) }
        return ["state": "yellow", "reason": "test", "checks": [:], "quality": [:]]
    }
    await state.applyLivePreviewCheck(SceneMetrics(faceBox: nil), logTrigger: "manual").value
    #expect(state.preCallState == "yellow")
    #expect(state.error?.contains("record could not be saved") == true)
}

@MainActor @Test func roomRefreshWaitsForExistingReadWithoutDuplicatingIt() async {
    let room = RoomControlService()
    let calls = RefreshCalls()
    room.transport = { _, args, _ in
        await calls.record(args[0])
        try await Task.sleep(for: .milliseconds(80))
        return "{}" // Invalid receipt still completes and stays unconfirmed.
    }
    room.refresh()
    await room.refreshAndWait()
    #expect(!room.isRefreshing)
    #expect(await calls.actions == ["status", "status"])
    #expect(room.summary("overheads").contains("Not confirmed"))
}

private actor RefreshCalls {
    var actions: [String] = []
    func record(_ action: String) { actions.append(action) }
}
