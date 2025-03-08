import UIKit

// MARK: - UIDeviceOrientation Extensions
extension UIDeviceOrientation {
    /// Check if the orientation is portrait (portrait or portraitUpsideDown)
    var isPortrait: Bool {
        return self == .portrait || self == .portraitUpsideDown
    }
    
    /// Check if the orientation is landscape (landscapeLeft or landscapeRight)
    var isLandscape: Bool {
        return self == .landscapeLeft || self == .landscapeRight
    }
    
    /// Check if the orientation is a valid interface orientation
    var isValidInterfaceOrientation: Bool {
        return isPortrait || isLandscape
    }
    
    /// Returns the rotation angle in degrees (0, 90, 180, 270) for video rotation
    var videoRotationAngleValue: CGFloat {
        switch self {
        case .landscapeRight:
            return 180.0
        case .portraitUpsideDown:
            return 270.0
        case .landscapeLeft:
            return 0.0
        case .portrait:
            return 90.0
        case .unknown, .faceUp, .faceDown:
            return 90.0
        @unknown default:
            return 90.0
        }
    }
    
    /// Transform to apply for video orientation based on device orientation
    var videoTransform: CGAffineTransform {
        switch self {
        case .landscapeRight:
            return CGAffineTransform(rotationAngle: CGFloat.pi)
        case .portraitUpsideDown:
            return CGAffineTransform(rotationAngle: -CGFloat.pi / 2)
        case .landscapeLeft:
            return .identity
        case .portrait:
            return CGAffineTransform(rotationAngle: CGFloat.pi / 2)
        case .unknown, .faceUp, .faceDown:
            return CGAffineTransform(rotationAngle: CGFloat.pi / 2)
        @unknown default:
            return CGAffineTransform(rotationAngle: CGFloat.pi / 2)
        }
    }
} 