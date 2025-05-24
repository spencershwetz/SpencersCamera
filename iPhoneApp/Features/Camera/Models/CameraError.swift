import Foundation

enum CameraError: Error, Identifiable {
    case cameraUnavailable
    case setupFailed
    case configurationFailed(message: String? = nil)
    case recordingFailed
    case savingFailed
    case whiteBalanceError
    case exposureError(message: String)
    case unauthorized
    case sessionFailedToStart
    case deviceUnavailable
    case invalidDeviceInput
    case custom(message: String)
    case mediaServicesWereReset
    case sessionRuntimeError(code: Int)
    case sessionInterrupted
    case retryExhausted(operation: String)
    case circuitBreakerOpen
    
    var id: String { description }
    
    var description: String {
        switch self {
        case .cameraUnavailable:
            return "Camera device not available"
        case .setupFailed:
            return "Failed to setup camera"
        case .configurationFailed(let message):
            return message ?? "Failed to configure camera settings"
        case .recordingFailed:
            return "Failed to record video"
        case .savingFailed:
            return "Failed to save video to photo library"
        case .whiteBalanceError:
            return "Failed to adjust white balance settings"
        case .exposureError(let message):
            return "Exposure error: \(message)"
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
        case .retryExhausted(let operation):
            return "Failed to \(operation) after multiple attempts"
        case .circuitBreakerOpen:
            return "Too many errors occurred. Please wait a moment and try again"
        }
    }
    
    /// Determines if the error is recoverable or should be shown to user
    var isRecoverable: Bool {
        switch self {
        case .sessionInterrupted, .circuitBreakerOpen, .retryExhausted:
            return true
        case .unauthorized, .mediaServicesWereReset:
            return false
        default:
            return true
        }
    }
    
    /// Suggested recovery action for the error
    var recoveryAction: String? {
        switch self {
        case .unauthorized:
            return "Go to Settings"
        case .mediaServicesWereReset:
            return "Restart App"
        case .circuitBreakerOpen:
            return "Wait a moment"
        case .sessionInterrupted:
            return "Please wait..."
        default:
            return nil
        }
    }
}
