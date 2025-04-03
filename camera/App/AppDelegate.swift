import UIKit
import SwiftUI

/// Main application delegate that handles orientation locking and other app-level functionality
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    // MARK: - Orientation Lock Properties

    /// Static variable to track view controllers that need landscape support
    static var landscapeEnabledViewControllers: [String] = [
        "VideoLibraryView",
        "VideoPlayerView",
        "OrientationFixViewController",
        "PresentationHostingController" // Added to handle SwiftUI presentations
    ]

    // Track if the video library is currently being presented
    static var isVideoLibraryPresented: Bool = false

    static let allowedViews = [
        "CameraView",
        "SettingsView",
        "OrientationFixView",
        "RotatingView"
    ]
    
    // App-wide state
    static var isDebugEnabled: Bool = false

    // MARK: - Application Lifecycle

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        print("DEBUG: AppDelegate - Application launching")

        // Create window (necessary for SceneDelegate-less apps)
        window = UIWindow(frame: UIScreen.main.bounds)
        
        // Configure root view controller
        let contentView = CameraView() // Changed back to CameraView
        let hostingController = UIHostingController(rootView: contentView)

        // Set modal presentation style
        hostingController.modalPresentationStyle = .overFullScreen

        // Set window properties
        window?.rootViewController = hostingController
        window?.makeKeyAndVisible()

        // Register for device orientation notifications
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Stop device orientation notifications to clean up
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    // MARK: - Debug Helpers

    // MARK: - Orientation Support

    /// Handle orientation lock dynamically based on the current view controller
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // Always enforce portrait orientation
        print("DEBUG: Enforcing portrait orientation")
        return .portrait
    }
}

// MARK: - Extensions

extension UIViewController {
    /// Get the top-most presented view controller
    func topMostViewController() -> UIViewController {
        if let presented = self.presentedViewController {
            // If the presented VC is a navigation controller, check its visible VC
            if let navigation = presented as? UINavigationController {
                return navigation.visibleViewController?.topMostViewController() ?? navigation
            }
            // If the presented VC is a tab bar controller, check its selected VC
             if let tab = presented as? UITabBarController {
                 return tab.selectedViewController?.topMostViewController() ?? tab
             }
            // Otherwise, recurse on the presented VC
            return presented.topMostViewController()
        }

        // Handle container view controllers if not presenting
        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.topMostViewController() ?? navigation
        }

        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.topMostViewController() ?? tab
        }

        // Base case: the view controller itself
        return self
    }
}