import Foundation

struct ProviderProfile: Identifiable, Codable, Equatable {
    let id: String
    var displayName: String
    var endpoint: String
    var model: String
    var isBuiltin: Bool
    var customModels: [String]
}
