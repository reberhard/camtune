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
    // Foundation Pipe/FileHandle lifetime is not a resource cleanup contract.
    // Explicitly release both ends, including when Process.run() throws.
    static func closePipes(_ pipes: Pipe?...) {
        for pipe in pipes.compactMap({ $0 }) {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        // Controllers handle SIGTERM cooperatively (curtains must send Stop).
        // Keep that contract; do not force-kill a device operation.
        process.terminate()
    }

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
        try Task.checkCancellation()
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
        defer {
            stop(process)
            closePipes(stdout, stderr, stdin)
        }
        if let stdin {
            process.standardInput = stdin
        }

        let operation = UUID().uuidString
        // Never persist stdin, JSON payloads, prompts, or arbitrary argv.
        let context = ["operation": operation, "executable": executableURL.path,
                       "command": arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                       "subcommand": arguments.dropFirst().first.flatMap {
                           $0.range(of: #"^[a-zA-Z][a-zA-Z-]{0,40}$"#, options: .regularExpression) != nil ? $0 : nil
                       } ?? ""]
        do {
        try process.run()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            async let stdoutData = stdout.fileHandleForReading.readToEnd() ?? Data()
            async let stderrData = stderr.fileHandleForReading.readToEnd() ?? Data()
            if let input, let stdin {
                try stdin.fileHandleForWriting.write(contentsOf: input)
                try stdin.fileHandleForWriting.close()
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while process.isRunning {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    stop(process)
                    throw ShellError.timeout
                }
                defer { group.cancelAll() }
                try await group.next()
            }

            let out = String(data: try await stdoutData, encoding: .utf8) ?? ""
            let err = String(data: try await stderrData, encoding: .utf8) ?? ""
            try Task.checkCancellation()
            if !acceptedExitCodes.contains(process.terminationStatus) {
                throw ShellError.nonZeroExit(process.terminationStatus, stderr: err)
            }
            return out
        } onCancel: {
            stop(process)
        }
        } catch {
            Diagnostics.shared.failure(error, action: "subprocess", context: context)
            throw error
        }
    }
}
