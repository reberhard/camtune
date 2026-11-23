import Foundation
import Testing
@testable import OjoApp

// 2026-11-23: Ojo looked for cameras once at launch and never again, so an iPhone
// that dropped and rejoined stayed invisible until Ojo was restarted.

@MainActor @Test func aBurstOfCameraEventsRefreshesOnce() async throws {
    let state = AppState()
    state.cameraChangeSettle = .milliseconds(100)
    var refreshes = 0
    state.cameraRefreshOverride = { refreshes += 1 }
    for _ in 0..<20 { state.cameraListChanged() }
    try await Task.sleep(for: .milliseconds(400))
    #expect(refreshes == 1)
}

@MainActor @Test func separateCameraEventsEachRefresh() async throws {
    let state = AppState()
    state.cameraChangeSettle = .milliseconds(50)
    var refreshes = 0
    state.cameraRefreshOverride = { refreshes += 1 }
    state.cameraListChanged()
    try await Task.sleep(for: .milliseconds(250))
    state.cameraListChanged()
    try await Task.sleep(for: .milliseconds(250))
    #expect(refreshes == 2)
}
