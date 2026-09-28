import Foundation
import OSLog

/// One local, bounded journal for UI messages and their underlying failures.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    let directory: URL
    private let lock = NSLock()
    private let session = UUID().uuidString
    private let limit: Int
    private let fallback = Logger(subsystem: "com.ojo.app", category: "diagnostics")
    private var lastVisible: [String: String] = [:]
    private(set) var writeFailure: String?

    init(directory: URL? = nil, limit: Int = 2_000_000) {
        self.directory = directory ?? ProcessInfo.processInfo.environment["OJO_DIAGNOSTICS_DIRECTORY"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/camtune/diagnostics")
        self.limit = limit
    }

    static func safe(_ value: String) -> String {
        var text = value
        for pattern in [#"(?i)("(?:token|password|secret|api[_-]?key)"\s*:\s*")[^"]+"#,
                        #"(?i)(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s,;]+"#,
                        #"(?i)((?:token|password|secret|api[_-]?key)\s*[=:]\s*)[^\s,;]+"#] {
            text = text.replacingOccurrences(of: pattern, with: "$1[redacted]", options: .regularExpression)
        }
        return String(text.prefix(8000))
    }

    @discardableResult
    func record(_ kind: String, _ message: String, context: [String: String] = [:]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var row = context.mapValues(Self.safe)
        row["event"] = kind
        row["message"] = Self.safe(message)
        row["timestamp"] = ISO8601DateFormatter().string(from: Date())
        row["session"] = session
        row["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        row["version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "test"
        row["build"] = Bundle.main.infoDictionary?["OjoSourceCommit"] as? String ?? "unversioned"
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("errors.jsonl")
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
               size.intValue >= limit {
                let previous = directory.appendingPathComponent("errors.previous.jsonl")
                if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                try fm.moveItem(at: url, to: previous)
            }
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(10)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            writeFailure = nil
            return true
        } catch {
            writeFailure = error.localizedDescription
            fallback.error("Journal write failed: \(error.localizedDescription, privacy: .public); event=\(kind, privacy: .public); message=\(Self.safe(message), privacy: .public)")
            return false
        }
    }

    func visible(_ message: String, source: String) {
        let safe = Self.safe(message)
        lock.lock()
        let changed = lastVisible[source] != safe
        lastVisible[source] = safe
        lock.unlock()
        if changed { record("visible_text", message, context: ["source": source]) }
    }

    func failure(_ error: Error, action: String, context: [String: String] = [:]) {
        let ns = error as NSError
        var fields = context
        fields["action"] = action
        fields["error_domain"] = ns.domain
        fields["error_code"] = String(ns.code)
        fields["error_type"] = String(reflecting: type(of: error))
        record("failure", error.localizedDescription, context: fields)
    }
}
