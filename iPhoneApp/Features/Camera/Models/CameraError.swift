import Foundation

enum CameraError: Error, Identifiable {
    case cameraUnavailable
    case setupFailed
    case configurationFailed
    case recordingFailed
    case savingFailed
    case whiteBalanceError
    case unauthorized
    case sessionFailedToStart
    case deviceUnavailable
    case invalidDeviceInput
    case custom(message: String)
    case mediaServicesWereReset
    case sessionRuntimeError(code: Int)
    case sessionInterrupted
    
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
        case .whiteBalanceError:
            return "Failed to adjust white balance settings"
        case .unauthorized:
            return "Camera access denied. Please allow camera access in Settings."
        case .sessionFailedToStart:
            return "Failed to start camera session"
        case .deviceUnavailable:
            return "Requested camera device is not available"
        case .invalidDeviceInput:
            return "Cannot add camera device input to session"
        case .custom(let message):
            return message
        case .mediaServicesWereReset:
            return "Media services were reset. Please try restarting the app."
        case .sessionRuntimeError(let code):
            return "An unexpected session runtime error occurred (Code: \(code))."
        case .sessionInterrupted:
            return "Camera session was interrupted. Please wait..."
        }
    }
}
