import Foundation
import Testing
@testable import OjoApp

private let testCamera = CameraDevice(name: "Test", vendor: 1, product: 2, address: nil)
private actor CameraCalls {
    var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
}

@MainActor @Test func cameraSlidersCoalesceAndOnlyConfirmReadback() async throws {
    let service = CameraControlService()
    let calls = CameraCalls()
    service.transport = { _, settings, _, _ in
        await calls.add(settings.intValue(for: "brightness")!)
        return settings
    }
    for value in 30...80 { service.set("brightness", value: .int(value), device: testCamera) { _ in } }
    #expect(service.observed.intValue(for: "brightness") == nil)
    #expect(service.pending.contains("brightness"))
    try await Task.sleep(for: .milliseconds(400))
    #expect(await calls.values == [80])
    #expect(service.observed.intValue(for: "brightness") == 80)
}

@MainActor @Test func failedCameraReadbackPersistsUntilRetry() async throws {
    let service = CameraControlService()
    service.transport = { _, _, _, _ in UVCSettings(values: ["brightness": .int(20)]) }
    service.set("brightness", value: .int(30), device: testCamera) { _ in Issue.record("Must not confirm") }
    try await Task.sleep(for: .milliseconds(350))
    #expect(service.errors["brightness"] != nil)
    #expect(service.observed.intValue(for: "brightness") == nil)
    service.transport = { _, settings, _, _ in settings }
    service.set("brightness", value: .int(30), device: testCamera) { _ in }
    try await Task.sleep(for: .milliseconds(350))
    #expect(service.errors["brightness"] == nil)
    #expect(service.observed.intValue(for: "brightness") == 30)
}

@MainActor @Test func cameraLateResultCannotOverwriteNewIntent() async throws {
    let service = CameraControlService()
    service.transport = { _, settings, _, _ in
        if settings.intValue(for: "brightness") == 30 {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return settings
    }
    service.set("brightness", value: .int(30), device: testCamera) { _ in }
    try await Task.sleep(for: .milliseconds(270))
    service.set("brightness", value: .int(80), device: testCamera) { _ in }
    try await Task.sleep(for: .milliseconds(600))
    #expect(service.observed.intValue(for: "brightness") == 80)
}

@Test func rangeUsesDeviceResolution() {
    let range = UVCRange(min: 10, max: 30, step: 4)
    #expect(range.clamp(25) == 22)
    #expect(range.clamp(200) == 30)
}

@Test func noFaceRetainsCaptureTimeRatherThanAnOldRectangle() {
    let captured = Date(timeIntervalSince1970: 100)
    let scene = SceneMetrics(faceBox: nil, faceCount: 0, measuredAt: captured)
    #expect(scene.faceBox == nil)
    #expect(scene.faceCenterX == nil)
    #expect(scene.measuredAt == captured)
    #expect(scene.faceCount == 0)
}

@MainActor @Test func swiftBridgeUsesSharedFailClosedAssessment() async throws {
    let support = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Support")
    let result = try await SceneContractService.call("assess", payload: [:], sourceDirectory: support)
    #expect(result["schema_version"] as? Int == 2)
    #expect(result["state"] as? String == "unknown")
    let checks = result["checks"] as? [String: [String: String]]
    #expect(checks?["exposure"]?["state"] == "unknown")
    #expect(checks?["white_balance"]?["state"] == "unknown")
}

@Test func fullCheckRetainsCanonicalGeometryAndPhotometry() {
    let scene = SceneMetrics(payload: ["face_box":[0.35,0.3,0.3,0.4],"face_count":1,
        "measured_at":100.0,"camera_id":"fixture","face_luma_mean":120.0,
        "face_luma_p05":50.0,"face_luma_p95":200.0,"rgb_balance":[1.0,1.0,1.0]])
    #expect(scene.faceCenterY == 0.5)
    #expect(scene.photometry["face_luma_p95"] == 200)
    #expect(scene.photometry["red_balance"] == 1)
    #expect(scene.cameraID == "fixture")
}
