import Foundation

enum DaemonStatus: Sendable {
    case notInstalled
    case running(pid: Int)
    case stopped
    case unknown

    var label: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .running(let pid): return "Running (PID \(pid))"
        case .stopped: return "Stopped"
        case .unknown: return "Unknown"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

enum DaemonService {
    private static let label = "com.camtune.daemon"
    private static let plistPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.camtune.daemon.plist")

    static func checkStatus() -> DaemonStatus {
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            return .notInstalled
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", label]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unknown
        }

        guard process.terminationStatus == 0 else {
            return .stopped
        }

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""

        // Parse PID from launchctl list output
        for line in output.components(separatedBy: .newlines) {
            if line.contains("\"PID\"") {
                let digits = line.filter(\.isNumber)
                if let pid = Int(digits) {
                    return .running(pid: pid)
                }
            }
        }

        return .stopped
    }
}
