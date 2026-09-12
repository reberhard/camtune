import Foundation

enum SceneContractService {
    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["OJO_SUPPORT_DIRECTORY"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projects/camtune/CamTuneApp/Support")
    }

    @MainActor static func call(_ command: String, payload: [String: Any], sourceDirectory: URL? = nil) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let output = try await ShellRunner.run(executablePath: "/opt/homebrew/bin/python3",
            arguments: [(sourceDirectory ?? supportDirectory).appendingPathComponent("scene_contract.py").path,
                        command, String(decoding: data, as: UTF8.self)], timeout: .seconds(5))
        guard let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }
}
