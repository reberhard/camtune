import Foundation
import Testing
@testable import OjoApp

@MainActor @Test func callLightSendsCallWhiteToAllLamps() async throws {
    let room = RoomControlService()
    let seen = Seen()
    room.transport = { _, args, _ in
        await seen.add(args)
        throw ShellError.timeout
    }
    room.light(LightService.callLightSceneID, target: "all")
    try await Task.sleep(for: .milliseconds(100))
    let args = await seen.args
    #expect(args.first?.prefix(2) == ["call-white", "all"])
}

private actor Seen {
    var args: [[String]] = []
    func add(_ a: [String]) { args.append(a) }
}
