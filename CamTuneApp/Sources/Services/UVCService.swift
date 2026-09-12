import Foundation

enum UVCService {
    static func listDevices() async throws -> [CameraDevice] {
        let output = try await ShellRunner.run("/opt/homebrew/bin/uvcc", arguments: ["devices"])
        guard !output.isEmpty else { return [] }
        return try JSONDecoder().decode([CameraDevice].self, from: Data(output.utf8))
    }

    static func exportSettings(vendor: Int, product: Int) async throws -> UVCSettings {
        try await transaction(UVCSettings(), vendor: vendor, product: product)
    }

    static func set(control: String, value: Int, vendor: Int, product: Int) async throws {
        _ = try await transaction(UVCSettings(values: [control: .int(value)]), vendor: vendor, product: product)
    }

    static func set(control: String, values: [Int], vendor: Int, product: Int) async throws {
        _ = try await transaction(UVCSettings(values: [control: .intArray(values)]), vendor: vendor, product: product)
    }

    static func getRanges(vendor: Int, product: Int) async throws -> [String: UVCRange] {
        let output: String
        do {
            output = try await ShellRunner.run(
                "/opt/homebrew/bin/uvcc",
                arguments: ["ranges", "--vendor", "\(vendor)", "--product", "\(product)"]
            )
        } catch {
            throw error
        }

        guard !output.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        guard let data = output.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }

        var result: [String: UVCRange] = [:]
        let unitResolution: Set<String> = ["brightness", "contrast", "saturation", "sharpness", "gain", "absolute_zoom"]
        for (key, info) in raw {
            if let dict = info as? [String: Any],
               let lo = dict["min"] as? Int,
               let hi = dict["max"] as? Int
            {
                if lo < hi, let step = (dict["res"] as? Int) ?? (dict["resolution"] as? Int) ?? (unitResolution.contains(key) ? 1 : nil), step > 0 {
                    result[key] = UVCRange(min: lo, max: hi, step: step)
                }
            } else if let arr = info as? [Int], arr.count == 2, arr[0] < arr[1], unitResolution.contains(key) {
                result[key] = UVCRange(min: arr[0], max: arr[1])
            }
        }

        return result
    }

    static func applySettings(_ settings: UVCSettings, vendor: Int, product: Int) async throws {
        _ = try await transaction(settings, vendor: vendor, product: product)
    }

    static func transaction(_ changes: UVCSettings, vendor: Int, product: Int,
                            operation: UUID = UUID(), issued: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000)) async throws -> UVCSettings {
        let encoded = try JSONEncoder().encode(changes)
        let payload: [String: Any] = ["vendor": vendor, "product": product,
            "changes": try JSONSerialization.jsonObject(with: encoded),
            "operation_id": operation.uuidString, "issued": issued]
        let input = try JSONSerialization.data(withJSONObject: payload)
        let output = try await ShellRunner.controller(executablePath: "/opt/homebrew/bin/python3",
            arguments: [SceneContractService.supportDirectory.appendingPathComponent("camera_control.py").path,
                        String(decoding: input, as: UTF8.self)], timeout: .seconds(20))
        guard let receipt = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              receipt["schema_version"] as? Int == 1,
              receipt["operation_id"] as? String == operation.uuidString,
              receipt["status"] as? String == "confirmed",
              let rows = receipt["devices"] as? [[String: Any]], rows.count == 1,
              rows[0]["device"] as? String == "camera:\(vendor):\(product)",
              rows[0]["observed_at"] is NSNumber,
              let observed = rows[0]["observed"] as? [String: Any],
              let settings = observed["settings"] as? [String: Any], !settings.isEmpty else {
            throw NSError(domain: "OjoCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera change not confirmed — refresh or retry"])
        }
        return try JSONDecoder().decode(UVCSettings.self, from: JSONSerialization.data(withJSONObject: settings))
    }
}
