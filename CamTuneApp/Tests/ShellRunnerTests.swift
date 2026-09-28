import Darwin
import Foundation
import Testing
@testable import OjoApp

@Suite(.serialized)
struct ShellRunnerTests {
    private func descriptorCount() -> Int {
        (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }

    @Test func repeatedCommandsReleaseDescriptors() async throws {
        _ = try await ShellRunner.run(executablePath: "/usr/bin/true")
        let baseline = descriptorCount()
        for _ in 0..<80 {
            _ = try await ShellRunner.run(executablePath: "/usr/bin/true")
        }
        #expect(descriptorCount() <= baseline + 2)
    }

    @Test func failurePathsReleaseDescriptors() async throws {
        _ = try await ShellRunner.run(executablePath: "/usr/bin/true")
        let baseline = descriptorCount()
        for _ in 0..<20 {
            do {
                _ = try await ShellRunner.run(executablePath: "/bin/sh", arguments: ["-c", "printf failure >&2; exit 7"])
                Issue.record("Expected a rejected exit")
            } catch ShellError.nonZeroExit(let code, let stderr) {
                #expect(code == 7)
                #expect(stderr == "failure")
            }
            do {
                _ = try await ShellRunner.run(executablePath: "/no-such-ojo-test-program")
                Issue.record("Expected launch failure")
            } catch {}
        }
        #expect(descriptorCount() <= baseline + 2)
    }

    @Test func inputAndControllerPartialResultArePreserved() async throws {
        let baseline = descriptorCount()
        for _ in 0..<20 {
            let output = try await ShellRunner.run(executablePath: "/bin/cat", input: Data("hello\n".utf8))
            #expect(output == "hello\n")
            let partial = try await ShellRunner.controller(executablePath: "/bin/sh",
                arguments: ["-c", "printf partial; exit 2"], timeout: .seconds(2))
            #expect(partial == "partial")
        }
        #expect(descriptorCount() <= baseline + 2)
    }

    @Test func timeoutReleasesDescriptors() async throws {
        let baseline = descriptorCount()
        for _ in 0..<5 {
            do {
                _ = try await ShellRunner.run(executablePath: "/bin/sleep", arguments: ["10"], timeout: .milliseconds(50))
                Issue.record("Expected timeout")
            } catch ShellError.timeout {}
        }
        #expect(descriptorCount() <= baseline + 2)
    }

    @Test func cancellationStopsChildAndReleasesDescriptors() async throws {
        let baseline = descriptorCount()
        let start = ContinuousClock.now
        let command = Task {
            try await ShellRunner.run(executablePath: "/bin/sleep", arguments: ["3"], timeout: .seconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        command.cancel()
        do {
            _ = try await command.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(descriptorCount() <= baseline + 2)
    }
}
