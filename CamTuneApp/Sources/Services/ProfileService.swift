import Foundation

enum ProfileService {
    static let profileDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/camtune")
    static let profilePath = profileDirectory.appendingPathComponent("profile.json")
    static let contextPresetsPath = profileDirectory.appendingPathComponent("app-presets.json")

    static func exists() -> Bool {
        FileManager.default.fileExists(atPath: profilePath.path)
    }

    static func load() throws -> UVCSettings {
        let data = try Data(contentsOf: profilePath)
        return try JSONDecoder().decode(UVCSettings.self, from: data)
    }

    static func save(_ settings: UVCSettings) throws {
        try FileManager.default.createDirectory(
            at: profileDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: profilePath)
    }

    static func saveContextPreset(
        settings: UVCSettings,
        appName: String?,
        qualityScore: Int?
    ) throws {
        try FileManager.default.createDirectory(
            at: profileDirectory, withIntermediateDirectories: true)
        var store = try loadContextPresetStore()
        let key = contextKey(appName: appName)
        let record = ContextPreset(
            savedAt: ISO8601DateFormatter().string(from: Date()),
            appName: appName ?? "manual",
            timeBucket: timeBucket(),
            qualityScore: qualityScore,
            settings: settings
        )
        store.presets[key] = record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store).write(to: contextPresetsPath)
    }

    static func loadContextPreset(appName: String?) throws -> UVCSettings? {
        let store = try loadContextPresetStore()
        let key = contextKey(appName: appName)
        if let preset = store.presets[key] {
            return preset.settings
        }
        return store.presets[contextKey(appName: nil)]?.settings
    }

    private static func loadContextPresetStore() throws -> ContextPresetStore {
        guard FileManager.default.fileExists(atPath: contextPresetsPath.path) else {
            return ContextPresetStore(presets: [:])
        }
        let data = try Data(contentsOf: contextPresetsPath)
        return try JSONDecoder().decode(ContextPresetStore.self, from: data)
    }

    private static func contextKey(appName: String?) -> String {
        "\(appName ?? "manual")-\(timeBucket())"
    }

    private static func timeBucket() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11: return "morning"
        case 11..<17: return "afternoon"
        case 17..<22: return "evening"
        default: return "night"
        }
    }
}

private struct ContextPresetStore: Codable {
    var presets: [String: ContextPreset]
}

private struct ContextPreset: Codable {
    let savedAt: String
    let appName: String
    let timeBucket: String
    let qualityScore: Int?
    let settings: UVCSettings
}
