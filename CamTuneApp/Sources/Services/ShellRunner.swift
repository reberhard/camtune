import Foundation

enum ShellError: LocalizedError {
    case nonZeroExit(Int32, stderr: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(let code, let stderr):
            return "Command failed (exit \(code)): \(stderr.prefix(500))"
        case .timeout:
            return "Command timed out"
        }
    }
}

enum ShellRunner {
    static func controller(executablePath: String, arguments: [String], timeout: Duration) async throws -> String {
        try await runProcess(executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments, input: nil, timeout: timeout, acceptedExitCodes: [0, 2])
    }
    private static let defaultPath = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")

    static func run(
        _ executable: String,
        arguments: [String] = [],
        timeout: Duration = .seconds(30)
    ) async throws -> String {
        try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [executable] + arguments,
            input: nil,
            timeout: timeout
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(
        executablePath: String,
        arguments: [String] = [],
        input: Data? = nil,
        timeout: Duration = .seconds(120)
    ) async throws -> String {
        try await runProcess(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            input: input,
            timeout: timeout
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        input: Data?,
        timeout: Duration,
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = defaultPath
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdin = input == nil ? nil : Pipe()
        if let stdin {
            process.standardInput = stdin
        }

        try process.run()
        if let input, let stdin {
            stdin.fileHandleForWriting.write(input)
            stdin.fileHandleForWriting.closeFile()
        }

        async let stdoutData = stdout.fileHandleForReading.readToEnd() ?? Data()
        async let stderrData = stderr.fileHandleForReading.readToEnd() ?? Data()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while process.isRunning {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                if process.isRunning {
                    process.terminate()
                }
                throw ShellError.timeout
            }
            try await group.next()
            group.cancelAll()
        }

        let out = String(data: try await stdoutData, encoding: .utf8) ?? ""
        let err = String(data: try await stderrData, encoding: .utf8) ?? ""
        if !acceptedExitCodes.contains(process.terminationStatus) {
            throw ShellError.nonZeroExit(process.terminationStatus, stderr: err)
        }
        return out
    }
}
