import UIKit
import SwiftUI
import os.log

/// Main application delegate that handles orientation locking and other app-level functionality
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    // Logger for AppDelegate
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "AppDelegateOrientation")

    // ADD: Access to the shared OrientationManager
    private let orientationManager = OrientationManager.shared

    // MARK: - Orientation Lock Properties - REMOVED
    /*
    /// Static variable to track view controllers that need landscape support
    static var landscapeEnabledViewControllers: [String] = []
    
    // Track if the video library is currently being presented
    static var isVideoLibraryPresented: Bool = false
    */
    // Track whether status bar should be hidden
    static var shouldHideStatusBar: Bool = true
    
    // MARK: - Application Lifecycle
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        print("DEBUG: AppDelegate - Application launching")
        
        // REMOVED: Manual window setup, root view controller assignment, and appearance settings.
        // The SwiftUI App lifecycle (@main, WindowGroup) will handle this.

        // Keep essential non-UI setup:
        logger.info("Setting up AppDelegate for iOS 18+")
        // Register for device orientation notifications
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        logger.info("Began generating device orientation notifications.")
        
        // REMOVED: Setup orientation lock observer (using custom CameraOrientationLock)
        // UIWindowScene.setupOrientationLockSupport()
        
        // Remove debug observer for orientation (if this was specific to the old setup)
        // NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        
        return true
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        // Stop device orientation notifications to clean up
        logger.info("Stopping device orientation notifications.")
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
    
    // MARK: - Orientation Support - RE-IMPLEMENTED
    
    /// Handle orientation lock dynamically based on the current state from OrientationManager
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        logger.debug("Querying supported interface orientations from OrientationManager.")
        // Read the current desired mask from the manager
        let mask = orientationManager.currentOrientationMask
        logger.info("AppDelegate returning orientation mask: \(mask == .portrait ? "Portrait" : "All")")
        return mask
    }
}

// MARK: - Extensions

extension UIViewController {
    /// Get the top-most presented view controller
    func topMostViewController() -> UIViewController {
        if let presented = self.presentedViewController {
            return presented.topMostViewController()
        }
        
        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.topMostViewController() ?? navigation
        }
        
        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.topMostViewController() ?? tab
        }
        
        return self
    }
}
