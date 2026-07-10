import Foundation

enum UVCService {
    static func listDevices() async throws -> [CameraDevice] {
        let output = try await ShellRunner.run("npx", arguments: ["uvcc", "devices"])
        guard !output.isEmpty else { return [] }
        return try JSONDecoder().decode([CameraDevice].self, from: Data(output.utf8))
    }

    static func exportSettings(vendor: Int, product: Int) async throws -> UVCSettings {
        let output = try await ShellRunner.run(
            "npx",
            arguments: ["uvcc", "export", "--vendor", "\(vendor)", "--product", "\(product)"]
        )
        guard !output.isEmpty else { return UVCSettings() }
        return try JSONDecoder().decode(UVCSettings.self, from: Data(output.utf8))
    }

    static func set(control: String, value: Int, vendor: Int, product: Int) async throws {
        _ = try await ShellRunner.run(
            "npx",
            arguments: [
                "uvcc", "set", control, "\(value)",
                "--vendor", "\(vendor)", "--product", "\(product)",
            ]
        )
    }

    static func set(control: String, values: [Int], vendor: Int, product: Int) async throws {
        _ = try await ShellRunner.run(
            "npx",
            arguments: [
                "uvcc", "set", control,
            ] + values.map(String.init) + [
                "--vendor", "\(vendor)", "--product", "\(product)",
            ]
        )
    }

    static func getRanges(vendor: Int, product: Int) async throws -> [String: UVCRange] {
        let output: String
        do {
            output = try await ShellRunner.run(
                "npx",
                arguments: ["uvcc", "ranges", "--vendor", "\(vendor)", "--product", "\(product)"]
            )
        } catch {
            return UVCRange.fallbacks
        }

        guard !output.isEmpty else { return UVCRange.fallbacks }

        guard let data = output.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return UVCRange.fallbacks }

        var result: [String: UVCRange] = [:]
        for (key, info) in raw {
            if let dict = info as? [String: Any],
               let lo = dict["min"] as? Int,
               let hi = dict["max"] as? Int
            {
                result[key] = UVCRange(min: lo, max: hi)
            } else if let arr = info as? [Int], arr.count == 2 {
                result[key] = UVCRange(min: arr[0], max: arr[1])
            }
        }

        return result.isEmpty ? UVCRange.fallbacks : result
    }

    static func applySettings(_ settings: UVCSettings, vendor: Int, product: Int) async throws {
        for (control, value) in settings.values {
            if case .int(let v) = value {
                try await set(control: control, value: v, vendor: vendor, product: product)
            } else if case .intArray(let values) = value {
                try await set(control: control, values: values, vendor: vendor, product: product)
            }
        }
    }
}
