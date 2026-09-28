import Foundation
import Testing
@testable import OjoApp

@Test func diagnosticsRetainFailureAndVisibleText() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = Diagnostics(directory: dir)
    log.failure(NSError(domain: NSPOSIXErrorDomain, code: 9), action: "refresh",
                context: ["device": "cafe", "operation": "test-operation"])
    log.visible("Café lamp: Bad file descriptor", source: "room.cafe")
    log.visible("Café lamp: Bad file descriptor", source: "room.cafe")
    let rows = try String(contentsOf: dir.appendingPathComponent("errors.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String] }
    #expect(rows.count == 2)
    #expect(rows[0]["error_code"] == "9")
    #expect(rows[0]["action"] == "refresh")
    #expect(rows[0]["operation"] == "test-operation")
    #expect(rows[1]["message"] == "Café lamp: Bad file descriptor")
    #expect(rows.allSatisfy { $0["timestamp"] != nil && $0["session"] != nil && $0["build"] != nil })
}

@Test func diagnosticsRotateAndRedact() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = Diagnostics(directory: dir, limit: 1)
    #expect(log.record("failure", "password=hunter2 token=abc123"))
    #expect(log.record("failure", "second"))
    let old = try String(contentsOf: dir.appendingPathComponent("errors.previous.jsonl"), encoding: .utf8)
    #expect(!old.contains("hunter2"))
    #expect(!old.contains("abc123"))
    #expect(old.contains("[redacted]"))
    #expect(try String(contentsOf: dir.appendingPathComponent("errors.jsonl"), encoding: .utf8).contains("second"))
}

@Test func diagnosticsWriteFailureIsReported() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let log = Diagnostics(directory: file)
    #expect(!log.record("failure", "test"))
    #expect(log.writeFailure != nil)
}

@MainActor @Test func roomTransportFailurePersistsWithoutAnOpenView() async throws {
    let marker = "room-test-" + UUID().uuidString
    let room = RoomControlService()
    room.transport = { _, _, _ in
        throw NSError(domain: "Fixture", code: 9, userInfo: [NSLocalizedDescriptionKey: marker])
    }
    await room.refreshAndWait()
    #expect(room.errors("all").allSatisfy { $0.contains(marker) })
    let text = try String(contentsOf: Diagnostics.shared.directory.appendingPathComponent("errors.jsonl"), encoding: .utf8)
    #expect(text.contains(marker))
    #expect(text.contains("transport_or_receipt"))
}

@Test func subprocessLaunchFailurePersists() async throws {
    let marker = "missing-ojo-executable-" + UUID().uuidString
    do {
        _ = try await ShellRunner.run(executablePath: "/tmp/" + marker)
        Issue.record("Missing executable must fail")
    } catch {
        let text = try String(contentsOf: Diagnostics.shared.directory.appendingPathComponent("errors.jsonl"), encoding: .utf8)
        #expect(text.contains(marker))
        #expect(text.contains("subprocess"))
    }
}

@MainActor @Test func cameraTransportFailurePersists() async throws {
    let marker = "camera-test-" + UUID().uuidString
    let camera = CameraControlService()
    camera.transport = { _, _, _, _ in
        throw NSError(domain: "Fixture", code: 9, userInfo: [NSLocalizedDescriptionKey: marker])
    }
    camera.set("brightness", value: .int(50), device: CameraDevice(name: "fixture", vendor: 1, product: 2, address: nil)) { _ in
        Issue.record("Failed camera write must not confirm")
    }
    for _ in 0..<100 {
        if !camera.pending.contains("brightness") { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(camera.errors["brightness"] == marker)
    let text = try String(contentsOf: Diagnostics.shared.directory.appendingPathComponent("errors.jsonl"), encoding: .utf8)
    #expect(text.contains(marker))
    #expect(text.contains("camera.set"))
}

@MainActor @Test func generalAppErrorPersistsBeforeDisplay() throws {
    let marker = "app-test-" + UUID().uuidString
    let state = AppState()
    state.error = marker
    state.error = nil
    let text = try String(contentsOf: Diagnostics.shared.directory.appendingPathComponent("errors.jsonl"), encoding: .utf8)
    #expect(text.contains(marker))
}

@Test func allViewTextUsesDiagnosticRendering() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let views = root.appendingPathComponent("Sources/Views")
    for file in try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" && file.lastPathComponent != "DiagnosticText.swift" {
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(source.range(of: #"\bText\("#, options: .regularExpression) == nil,
                "View text bypasses diagnostics in \(file.lastPathComponent)")
    }
}
