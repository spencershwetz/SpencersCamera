import UIKit
import SwiftUI
import os.log

// MARK: - UIDeviceOrientation Extensions

// Add a logger for orientation details
private let orientationLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Orientation")

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
        orientationLogger.debug("Calculating videoRotationAngleValue for device orientation: \\(self.rawValue)")
        let angle: CGFloat
        switch self {
        case .portrait:
            angle = 90.0  // Portrait mode: rotate 90° clockwise
        case .landscapeRight:  // USB port on left
            angle = 180.0  // Landscape with USB on left: rotate 180°
        case .landscapeLeft:  // USB port on right
            angle = 0.0  // Landscape with USB on right: no rotation
        case .portraitUpsideDown:
            angle = 270.0
        case .unknown, .faceUp, .faceDown:
            angle = 90.0  // Default to portrait mode
        @unknown default:
            angle = 90.0
        }
        orientationLogger.debug("Calculated videoRotationAngleValue: \\(angle)°")
        return angle
    }
    
    /// Transform to apply for video orientation based on device orientation
    var videoTransform: CGAffineTransform {
        orientationLogger.debug("Calculating videoTransform for device orientation: \\(self.rawValue)")
        let angle: CGFloat
        switch self {
        case .portrait:
            angle = .pi / 2  // 90° clockwise
        case .landscapeRight:  // USB port on left
            angle = .pi  // 180°
        case .landscapeLeft:  // USB port on right
            angle = 0  // No rotation
        case .portraitUpsideDown:
            angle = -.pi / 2  // 270°
        case .unknown, .faceUp, .faceDown:
            angle = .pi / 2  // Default to portrait mode
        @unknown default:
            angle = .pi / 2
        }
        let transform = CGAffineTransform(rotationAngle: angle)
        orientationLogger.debug("Calculated videoTransform angle: \\(angle) radians")
        return transform
    }
}

// ADD: StatusBarHidingModifier
struct StatusBarHidingModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .statusBar(hidden: true)
    }
}

extension View {
    func hideStatusBar() -> some View {
        modifier(StatusBarHidingModifier())
    }
}
