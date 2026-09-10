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
        // These targets must remain the exact groups accepted by
        // office-lights.py. The former key/accent/background aliases were UI
        // inventions; the controller rejected them and the UI hid the error.
        LightFixture(id: "overheads", name: "Overhead Lights", ip: "", target: "overheads",
                     hue: 30, saturation: 5, brightness: 30),
        LightFixture(id: "cafe", name: "Café Lamp", ip: "", target: "cafe",
                     hue: 25, saturation: 20, brightness: 25),
        LightFixture(id: "pie", name: "Floor Lamp", ip: "", target: "pie",
                     hue: 35, saturation: 3, brightness: 45),
    ]

    // Fixed 2026-09-03: this used to default to
    // ~/.config/camtune/office-lights.py, which does not exist, so
    // lightControlAvailable was false and every button in this view was a
    // no-op. The real script (the one env.json/AI Tune already use) is at
    // ~/clawd/scripts/office-lights.py. See specs/ojo.md Phase 1.
    private static var scriptPath: String {
        if let value = ProcessInfo.processInfo.environment["CAMTUNE_LIGHT_SCRIPT"], !value.isEmpty {
            return value
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("clawd/scripts/office-lights.py").path
    }

    // office-lights.py imports `kasa`, which is only installed under
    // Homebrew's python3.14, not the system /usr/bin/python3 (3.9). Using
    // the bare interpreter name depends on which PATH the calling process
    // happened to inherit; an absolute path removes that ambiguity for
    // every caller (GUI app, daemon, or a shell).
    private static let interpreterPath = "/opt/homebrew/bin/python3"

    static func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: interpreterPath)
            && FileManager.default.fileExists(atPath: scriptPath)
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
            executablePath: interpreterPath,
            arguments: args,
            timeout: .seconds(15)
        )
    }

    static func setCustomHSV(hue: Int, saturation: Int, brightness: Int, target: String) async throws {
        guard isAvailable() else {
            throw LightError.unavailable
        }
        _ = try await ShellRunner.run(
            executablePath: interpreterPath,
            arguments: [scriptPath, "custom", "\(hue)", "\(saturation)", "\(brightness)", target],
            timeout: .seconds(15)
        )
    }

    static func turnOff(target: String) async throws {
        guard isAvailable() else {
            throw LightError.unavailable
        }
        _ = try await ShellRunner.run(
            executablePath: interpreterPath,
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
