import Foundation

enum CameraError: Error, Identifiable {
    case cameraUnavailable
    case setupFailed
    case configurationFailed
    case recordingFailed
    case savingFailed
    
    var id: String { description }
    
    var description: String {
        switch self {
        case .cameraUnavailable:
            return "Camera device not available"
        case .setupFailed:
            return "Failed to setup camera"
        case .configurationFailed:
            return "Failed to configure camera settings"
        case .recordingFailed:
            return "Failed to record video"
        case .savingFailed:
            return "Failed to save video to photo library"
        }
    }
} 