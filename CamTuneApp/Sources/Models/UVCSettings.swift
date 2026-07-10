import Foundation

/// UVC settings as a flat dictionary matching the profile.json format from ojo.py.
/// Values can be Int or [Int] (e.g. absolute_pan_tilt).
struct UVCSettings: Sendable {
    var values: [String: SettingValue] = [:]

    enum SettingValue: Sendable, Equatable {
        case int(Int)
        case intArray([Int])
    }

    func intValue(for key: String) -> Int? {
        if case .int(let v) = values[key] { return v }
        return nil
    }

    func intArrayValue(for key: String) -> [Int]? {
        if case .intArray(let v) = values[key] { return v }
        return nil
    }

    static let displayControls = [
        "brightness", "contrast", "saturation", "gain",
        "sharpness", "white_balance_temperature",
    ]

    static let autoControls = [
        "auto_white_balance_temperature", "auto_exposure_mode", "auto_focus",
    ]
}

extension UVCSettings: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var result: [String: SettingValue] = [:]
        for key in container.allKeys {
            if let intVal = try? container.decode(Int.self, forKey: key) {
                result[key.stringValue] = .int(intVal)
            } else if let arr = try? container.decode([Int].self, forKey: key) {
                result[key.stringValue] = .intArray(arr)
            }
        }
        self.values = result
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            let codingKey = DynamicCodingKey(stringValue: key)!
            switch value {
            case .int(let v):
                try container.encode(v, forKey: codingKey)
            case .intArray(let arr):
                try container.encode(arr, forKey: codingKey)
            }
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}
