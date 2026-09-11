import Foundation
import Testing
@testable import OjoApp

private func response(_ args: [String], on: Bool, failed: Bool = false) -> String {
    let op = args.firstIndex(of: "--operation-id").map { args[$0 + 1] } ?? "read"
    let rows: [[String: Any]] = ["overhead-left", "overhead-right"].map { id in
        ["device": id, "operation_id": op, "status": failed && id == "overhead-right" ? "failed" : "confirmed",
         "observed": ["on": on, "brightness": 40], "observed_at": Date().timeIntervalSince1970,
         "error": failed && id == "overhead-right" ? "Unreachable" : NSNull()]
    }
    let data = try! JSONSerialization.data(withJSONObject: ["schema_version": 1, "operation_id": op,
        "status": failed ? "partial" : "confirmed", "devices": rows])
    return String(decoding: data, as: UTF8.self)
}

@MainActor @Test func offRemainsPendingUntilReadback() async throws {
    let room = RoomControlService()
    room.transport = { _, args, _ in
        try await Task.sleep(for: .milliseconds(50))
        return response(args, on: false)
    }
    #expect(room.summary("overheads") == "Unknown")
    room.light("off", target: "overheads")
    #expect(room.summary("overheads") == "Applying…")
    try await Task.sleep(for: .milliseconds(100))
    #expect(room.summary("overheads") == "Off")
}

@MainActor @Test func lateOnCannotOverwriteNewerOff() async throws {
    let room = RoomControlService()
    room.transport = { _, args, _ in
        let on = args[0] == "on"
        try await Task.sleep(for: on ? .milliseconds(100) : .milliseconds(10))
        return response(args, on: on)
    }
    room.light("on", target: "overheads")
    room.light("off", target: "overheads")
    try await Task.sleep(for: .milliseconds(180))
    #expect(room.summary("overheads") == "Off")
}

@MainActor @Test func partialFailureAndDismissalCannotShowConfirmedOff() async throws {
    let room = RoomControlService()
    room.transport = { _, args, _ in response(args, on: false, failed: true) }
    room.light("off", target: "overheads")
    try await Task.sleep(for: .milliseconds(50))
    #expect(room.errors("overheads").count == 1)
    #expect(room.summary("overheads").contains("Not confirmed"))
    room.dismiss("overheads")
    #expect(room.errors("overheads").isEmpty)
    #expect(room.summary("overheads").contains("Not confirmed"))
}

@MainActor @Test func malformedOutputIsFailure() async throws {
    let room = RoomControlService()
    room.transport = { _, _, _ in "" }
    room.light("off", target: "overheads")
    try await Task.sleep(for: .milliseconds(50))
    #expect(room.errors("overheads").count == 2)
    #expect(room.summary("overheads") != "Off")
}

private actor Calls {
    var actions: [String] = []
    func add(_ action: String) { actions.append(action) }
}

@MainActor @Test func offCancelsDebouncedSlider() async throws {
    let room = RoomControlService()
    let calls = Calls()
    room.transport = { _, args, _ in
        await calls.add(args[0])
        return response(args, on: false)
    }
    room.adjust(target: "overheads", hue: 30, saturation: 5, brightness: 50)
    room.light("off", target: "overheads")
    try await Task.sleep(for: .milliseconds(400))
    #expect(await calls.actions == ["off"])
    #expect(room.summary("overheads") == "Off")
}
