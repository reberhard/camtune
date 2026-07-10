import Foundation

enum AudioRoute: String, CaseIterable, Sendable {
    case tv = "tv"
    case homepod = "homepod"
    case both = "both"

    var label: String {
        switch self {
        case .tv: return "TV"
        case .homepod: return "HomePod"
        case .both: return "Both"
        }
    }
}

enum TVService {
    private static var atvScriptPath: String {
        if let value = ProcessInfo.processInfo.environment["CAMTUNE_TV_SCRIPT"], !value.isEmpty {
            return value
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/camtune/atv-audio.py").path
    }

    private static var concertScriptPath: String {
        if let value = ProcessInfo.processInfo.environment["CAMTUNE_CONCERT_SCRIPT"], !value.isEmpty {
            return value
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/camtune/concert-start.sh").path
    }

    static func playPause() async throws {
        _ = try await ShellRunner.run(
            executablePath: "/usr/bin/python3",
            arguments: [atvScriptPath, "play_pause"],
            timeout: .seconds(10)
        )
    }

    static func next() async throws {
        _ = try await ShellRunner.run(
            executablePath: "/usr/bin/python3",
            arguments: [atvScriptPath, "next"],
            timeout: .seconds(10)
        )
    }

    static func setAudioRoute(_ route: AudioRoute) async throws {
        _ = try await ShellRunner.run(
            executablePath: "/usr/bin/python3",
            arguments: [atvScriptPath, route.rawValue],
            timeout: .seconds(15)
        )
    }

    static func sleep() async throws {
        _ = try await ShellRunner.run(
            executablePath: "/usr/bin/python3",
            arguments: [atvScriptPath, "sleep"],
            timeout: .seconds(10)
        )
    }

    static func wake() async throws {
        _ = try await ShellRunner.run(
            executablePath: "/usr/bin/python3",
            arguments: [atvScriptPath, "wake"],
            timeout: .seconds(10)
        )
    }

    static func startConcertSeries() async throws {
        _ = try await ShellRunner.run(
            executablePath: "/bin/bash",
            arguments: [concertScriptPath],
            timeout: .seconds(30)
        )
    }
}
