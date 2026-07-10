import Foundation

struct LightFixture: Identifiable, Sendable {
    let id: String
    let name: String
    let ip: String
    let target: String
    var hue: Int = 30
    var saturation: Int = 5
    var brightness: Int = 50
    var isOn: Bool = true
}

struct LightScene: Identifiable, Sendable {
    let id: String
    let name: String
    let icon: String
}

enum LightService {
    static let scenes: [LightScene] = [
        LightScene(id: "warm-white", name: "Warm White", icon: "sun.max"),
        LightScene(id: "soft-rose", name: "Soft Rose", icon: "paintpalette"),
        LightScene(id: "warm-amber", name: "Warm Amber", icon: "flame"),
        LightScene(id: "lavender", name: "Lavender", icon: "moon.stars"),
        LightScene(id: "pitcher-green", name: "Pitcher Green", icon: "leaf"),
        LightScene(id: "70s-orange", name: "70s Orange", icon: "record.circle"),
        LightScene(id: "reading", name: "Reading", icon: "book"),
        LightScene(id: "off", name: "Off", icon: "power"),
    ]

    static let defaultFixtures: [LightFixture] = [
        LightFixture(id: "key-left", name: "Key Left", ip: "", target: "key",
                     hue: 30, saturation: 5, brightness: 30),
        LightFixture(id: "key-right", name: "Key Right", ip: "", target: "key",
                     hue: 30, saturation: 5, brightness: 30),
        LightFixture(id: "accent", name: "Accent Light", ip: "", target: "accent",
                     hue: 25, saturation: 20, brightness: 25),
        LightFixture(id: "background", name: "Background Light", ip: "", target: "background",
                     hue: 35, saturation: 3, brightness: 45),
    ]

    private static var scriptPath: String {
        if let value = ProcessInfo.processInfo.environment["CAMTUNE_LIGHT_SCRIPT"], !value.isEmpty {
            return value
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/camtune/office-lights.py").path
    }

    static func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: scriptPath)
    }

    static func applyScene(_ sceneId: String, target: String = "all") async throws {
        guard isAvailable() else {
            throw LightError.unavailable
        }
        let args: [String]
        if target == "all" {
            args = [scriptPath, sceneId]
        } else {
            args = [scriptPath, sceneId, target]
        }
        _ = try await ShellRunner.run(
            executablePath: "/usr/bin/python3",
            arguments: args,
            timeout: .seconds(15)
        )
    }

    static func setCustomHSV(hue: Int, saturation: Int, brightness: Int, target: String) async throws {
        guard isAvailable() else {
            throw LightError.unavailable
        }
        _ = try await ShellRunner.run(
            executablePath: "/usr/bin/python3",
            arguments: [scriptPath, "custom", "\(hue)", "\(saturation)", "\(brightness)", target],
            timeout: .seconds(15)
        )
    }

    static func turnOff(target: String) async throws {
        guard isAvailable() else {
            throw LightError.unavailable
        }
        _ = try await ShellRunner.run(
            executablePath: "/usr/bin/python3",
            arguments: [scriptPath, "off", target],
            timeout: .seconds(15)
        )
    }
}

enum LightError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Controllable desk lights are not available on this Mac"
    }
}
