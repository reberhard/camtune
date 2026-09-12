import Foundation

enum CallRollupService {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/camtune/pending-call-rollups")
    }
    struct Pending: Codable { let id: UUID; let arguments: [String] }

    static func enqueue(id: UUID, arguments: [String], root: URL = directory) throws {
        guard arguments.prefix(2) == ["calls","log"] else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(Pending(id:id,arguments:arguments))
            .write(to:root.appendingPathComponent(id.uuidString+".json"),options:.atomic)
    }

    static func flush(root: URL = directory,
                      writer: @Sendable ([String]) async throws -> Void) async -> [String] {
        guard FileManager.default.fileExists(atPath:root.path) else { return [] }
        do {
            let files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            var failures: [String] = []
            for file in files where file.pathExtension == "json" {
                do {
                    let row = try JSONDecoder().decode(Pending.self,from:Data(contentsOf:file))
                    guard file.lastPathComponent == row.id.uuidString+".json", row.arguments.prefix(2) == ["calls","log"] else { throw CocoaError(.fileReadCorruptFile) }
                    try await writer(row.arguments)
                    try FileManager.default.removeItem(at:file)
                } catch { failures.append(file.lastPathComponent+": "+error.localizedDescription) }
            }
            return failures
        } catch { return [error.localizedDescription] }
    }
}
