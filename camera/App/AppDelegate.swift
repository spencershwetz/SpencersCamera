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

        // Force dark mode at UIApplication level
        window?.enforceDarkMode()

        // Update to use UIWindowScene.windows
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.windows.forEach { window in
                window.enforceDarkMode()

                // Disable safe area insets for all windows
                // window.rootViewController?.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0) // Let views manage this if needed
            }
        }

        // Create and configure window
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = .black

        // Configure root view controller
        let contentView = CameraView() // Changed back to CameraView
        let hostingController = UIHostingController(rootView: contentView)
        hostingController.view.backgroundColor = .black

        // Force dark mode for view controller
        hostingController.overrideUserInterfaceStyle = .dark

        // Set modal presentation style
        hostingController.modalPresentationStyle = .overFullScreen

        // Disable safe area insets completely - moved to CameraView/ContentView if needed
        // hostingController.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)
        // hostingController.view.frame = UIScreen.main.bounds

        // Set window properties
        window?.rootViewController = hostingController
        window?.makeKeyAndVisible()

        // Disable safe area insets at window level again - moved to views if needed
        // window?.rootViewController?.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)

        // Force dark mode again after window is visible
        window?.enforceDarkMode()

        // Force black backgrounds
        if let rootView = window?.rootViewController?.view {
            forceBlackBackgrounds(rootView)
        }

        // Inspect view hierarchy colors
        // inspectViewHierarchyBackgroundColors(hostingController.view) // Commented out for cleaner logs

        // Register for device orientation notifications
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        // Setup orientation lock observer
        // UIWindowScene.setupOrientationLockSupport() // Let AppDelegate handle it directly

        // Remove debug observer for orientation
        // NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil) // Let AppDelegate handle it

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Stop device orientation notifications to clean up
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    // MARK: - Debug Helpers

    private func inspectViewHierarchyBackgroundColors(_ view: UIView, level: Int = 0) {
        let indent = String(repeating: "  ", count: level)
        print("\(indent)DEBUG: View \(type(of: view)) - backgroundColor: \(view.backgroundColor?.debugDescription ?? "nil")")

        // Get superview chain
        if level == 0 {
            var currentView: UIView? = view
            var superviewLevel = 0
            while let superview = currentView?.superview {
                print("\(indent)DEBUG: Superview \(superviewLevel) - Type: \(type(of: superview)) - backgroundColor: \(superview.backgroundColor?.debugDescription ?? "nil")")
                currentView = superview
                superviewLevel += 1
            }
        }

        for subview in view.subviews {
            inspectViewHierarchyBackgroundColors(subview, level: level + 1)
        }
    }

    // MARK: - Helper to force black backgrounds

    private func forceBlackBackgrounds(_ view: UIView) {
        // Force black background on the view itself
        view.backgroundColor = .black

        // Special handling for system views
        let systemViewClasses = [
            "UIDropShadowView",
            "UITransitionView",
            "UINavigationTransitionView",
            "_UIInteractiveHighlightEffectWindow"
        ]

        for className in systemViewClasses {
            if let viewClass = NSClassFromString(className),
               view.isKind(of: viewClass) {
                view.backgroundColor = .black
                view.layer.backgroundColor = UIColor.black.cgColor
            }
        }

        // Handle status bar background
        if view.bounds.height <= 50 && view.bounds.minY == 0 {
            view.backgroundColor = .black
            view.layer.backgroundColor = UIColor.black.cgColor
        }

        // Recursively process subviews
        for subview in view.subviews {
            forceBlackBackgrounds(subview)
        }
    }

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


// MARK: - UIWindow Extension
extension UIWindow {
    /// Enforce dark mode for the window
    func enforceDarkMode() {
        if #available(iOS 13.0, *) {
            self.overrideUserInterfaceStyle = .dark
        }
    }
}