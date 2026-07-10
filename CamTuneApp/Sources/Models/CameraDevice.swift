import Foundation

struct CameraDevice: Codable, Sendable {
    let name: String
    let vendor: Int
    let product: Int
    let address: Int?

    enum CodingKeys: String, CodingKey {
        case name, vendor, product, address
    }
}
