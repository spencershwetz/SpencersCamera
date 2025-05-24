import Foundation

/// Represents the current exposure control mode
enum ExposureMode: String, Codable, Equatable {
    case auto
    case manual
    case shutterPriority
    case locked
}