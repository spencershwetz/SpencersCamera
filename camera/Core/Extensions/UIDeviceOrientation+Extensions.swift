import UIKit
import SwiftUI

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
        case .portrait:
            return 90.0  // Portrait mode: rotate 90° clockwise
        case .landscapeRight:  // USB port on left
            return 180.0  // Landscape with USB on left: rotate 180°
        case .landscapeLeft:  // USB port on right
            return 0.0  // Landscape with USB on right: no rotation
        case .portraitUpsideDown:
            return 270.0
        case .unknown, .faceUp, .faceDown:
            return 90.0  // Default to portrait mode
        @unknown default:
            return 90.0
        }
    }
    
    /// Transform to apply for video orientation based on device orientation
    var videoTransform: CGAffineTransform {
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
        return CGAffineTransform(rotationAngle: angle)
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
