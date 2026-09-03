import Foundation

struct CurtainStatus: Sendable {
    let target: String
    var positionPercent: Int?
    var isMoving: Bool
    var reachable: Bool
}

enum CurtainService {
    // office-blinds.py imports tinytuya, which (like kasa for the lights)
    // is only installed under Homebrew's python3.14. Absolute paths for
    // both the interpreter and the script, same reasoning as LightService.
    private static var scriptPath: String {
        if let value = ProcessInfo.processInfo.environment["CAMTUNE_BLINDS_SCRIPT"], !value.isEmpty {
            return value
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("clawd/scripts/office-blinds.py").path
    }

    private static let interpreterPath = "/opt/homebrew/bin/python3"

    static func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: interpreterPath)
            && FileManager.default.fileExists(atPath: scriptPath)
    }

    /// Parses office-blinds.py's own log lines, e.g.:
    ///   "  OK  Curtain Left (192.168.50.131): position=40% control=stop"
    ///   "  FAIL Curtain Right (...): <error>"
    static func status(target: String = "both") async throws -> [String: CurtainStatus] {
        guard isAvailable() else { throw CurtainError.unavailable }
        let output = try await ShellRunner.run(
            executablePath: interpreterPath,
            arguments: [scriptPath, "status", target],
            timeout: .seconds(20)
        )
        return parseStatusLines(output)
    }

    static func open(target: String = "both") async throws {
        try await run(["open", target], timeout: .seconds(30))
    }

    static func close(target: String = "both") async throws {
        try await run(["close", target], timeout: .seconds(30))
    }

    static func stop(target: String = "both") async throws {
        try await run(["stop", target], timeout: .seconds(20))
    }

    /// Timed-pulse positioning, closed-loop corrected against the motor's
    /// own readback (office-blinds.py's own mechanism). Slow: a full-range
    /// move takes real seconds, not milliseconds.
    static func setPosition(_ percent: Int, target: String = "both") async throws {
        try await run(["set", "\(percent)", target], timeout: .seconds(120))
    }

    private static func run(_ args: [String], timeout: Duration) async throws {
        guard isAvailable() else { throw CurtainError.unavailable }
        _ = try await ShellRunner.run(
            executablePath: interpreterPath,
            arguments: [scriptPath] + args,
            timeout: timeout
        )
    }

    static func parseStatusLines(_ output: String) -> [String: CurtainStatus] {
        var result: [String: CurtainStatus] = [:]
        for line in output.split(separator: "\n") {
            let text = String(line)
            guard let nameRange = text.range(of: "Curtain (Left|Right)", options: .regularExpression)
            else { continue }
            let name = String(text[nameRange])
            let reachable = text.contains("OK")
            var position: Int?
            var moving = false
            if let posRange = text.range(of: "position=(-?\\d+)%", options: .regularExpression) {
                let digits = text[posRange].dropFirst("position=".count).dropLast()
                position = Int(digits)
            }
            if let ctrlRange = text.range(of: "control=(\\w+)", options: .regularExpression) {
                let word = text[ctrlRange].dropFirst("control=".count)
                moving = word == "open" || word == "close"
            }
            result[name] = CurtainStatus(
                target: name, positionPercent: position, isMoving: moving, reachable: reachable)
        }
        return result
    }
}

enum CurtainError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Curtain control (office-blinds.py) is not available on this Mac"
    }
}
