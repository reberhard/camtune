import Foundation

struct OptimizationResult: Codable, Sendable {
    let assessment: String?
    let changes: [String: Int]?
    let auto_white_balance_temperature: Int?
    let auto_exposure_mode: Int?

    var hasChanges: Bool {
        let hasControl = !(changes ?? [:]).isEmpty
        return hasControl || auto_white_balance_temperature != nil || auto_exposure_mode != nil
    }
}
