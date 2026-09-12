import Foundation

struct UVCRange: Sendable {
    let min: Int
    let max: Int
    var step: Int = 1

    func clamp(_ value: Int) -> Int {
        let bounded = Swift.min(Swift.max(value, min), max)
        return min + ((bounded - min) / Swift.max(1, step)) * Swift.max(1, step)
    }
}

extension UVCRange {
    /// Fallback ranges for common UVC controls when uvcc ranges query fails.
    static let fallbacks: [String: UVCRange] = [
        "white_balance_temperature": UVCRange(min: 2800, max: 7500),
        "brightness": UVCRange(min: 0, max: 255),
        "contrast": UVCRange(min: 0, max: 255),
        "gain": UVCRange(min: 0, max: 255),
        "saturation": UVCRange(min: 0, max: 255),
        "sharpness": UVCRange(min: 0, max: 255),
        "exposure_time_absolute": UVCRange(min: 3, max: 2047),
    ]
}
