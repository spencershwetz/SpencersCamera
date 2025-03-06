import UIKit

/// Extension to support orientation locking in the app
extension UIApplicationDelegate {
    /// This method should be called in your AppDelegate's application(_:supportedInterfaceOrientationsFor:) method
    func getSupportedOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        return CameraOrientationLock.getCurrentOrientationLock()
    }
}

/// Extension to support orientation locking in SwiftUI App
@available(iOS 14.0, *)
extension UIApplication {
    /// Override the supportedInterfaceOrientations for the app
    static func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        return CameraOrientationLock.getCurrentOrientationLock()
    }
} 