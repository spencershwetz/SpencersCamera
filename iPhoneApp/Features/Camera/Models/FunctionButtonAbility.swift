import Foundation

/// Represents the different actions that can be assigned to a function button.
enum FunctionButtonAbility: String, CaseIterable, Identifiable {
    case none = "None"
    case lockExposure = "Lock Exposure"
    case shutterPriority = "Shutter Priority"
    // Add more abilities here in the future

    var id: String { self.rawValue }

    // Provides a user-friendly display name
    var displayName: String {
        return self.rawValue
    }
} 