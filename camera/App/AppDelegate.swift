import UIKit
import SwiftUI
import os.log

/// Main application delegate that handles orientation locking and other app-level functionality
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    // Logger for AppDelegate
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "AppDelegateOrientation")

    // MARK: - Orientation Lock Properties
    
    /// Static variable to track view controllers that need landscape support
    static var landscapeEnabledViewControllers: [String] = [
        "VideoLibraryView", 
        "VideoPlayerView",
        "OrientationFixViewController",
        "PresentationHostingController"
    ]
    
    // Track if the video library is currently being presented
    static var isVideoLibraryPresented: Bool = false
    
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
    
    // MARK: - Orientation Support
    
    /// Handle orientation lock dynamically based on the current view controller
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        logger.debug("Querying supported interface orientations.")
        // If video library is flagged as presented, always allow landscape
        if AppDelegate.isVideoLibraryPresented {
            logger.info("Video library is presented. Allowing Portrait and Landscape Left/Right.")
            return [.portrait, .landscapeLeft, .landscapeRight]
        }
        
        // Get the top view controller
        if let topViewController = window?.rootViewController?.topMostViewController() {
            let vcName = String(describing: type(of: topViewController))
            logger.debug("Top view controller identified: \(vcName)")
            
            // Check if this is a presentation controller that contains our view
            if vcName.contains("PresentationHostingController") {
                // For SwiftUI presentation controllers, we need to check their content
                if let childController = topViewController.children.first {
                    let childName = String(describing: type(of: childController))
                    logger.debug("PresentationHostingController contains child: \(childName)")
                    
                    // Check if the child controller is allowed to use landscape
                    if AppDelegate.landscapeEnabledViewControllers.contains(where: { childName.contains($0) }) {
                        logger.info("Child controller \(childName) allows landscape. Allowing Portrait and Landscape Left/Right.")
                        return [.portrait, .landscapeLeft, .landscapeRight]
                    } else {
                        logger.info("Child controller \(childName) does not require landscape. Locking to Portrait.")
                        return .portrait
                    }
                } else {
                    logger.warning("PresentationHostingController has no children. Locking to Portrait.")
                    return .portrait
                }
            }
            
            // Check if the current view controller allows landscape
            if let orientationViewController = topViewController as? OrientationFixViewController {
                // Use property from our custom view controller
                if orientationViewController.allowsLandscapeMode {
                    logger.info("OrientationFixViewController allows landscape. Allowing Portrait and Landscape Left/Right.")
                    return [.portrait, .landscapeLeft, .landscapeRight]
                }
            }
            
            // Check the VC name against our list
            if AppDelegate.landscapeEnabledViewControllers.contains(where: { vcName.contains($0) }) {
                logger.info("    [Orientation] Top VC '\(vcName)' allows landscape via static list. Allowing All.")
                return [.portrait, .landscapeLeft, .landscapeRight]
            }
            
            logger.info("    [Orientation] No special case matched for VC '\(vcName)'. Locking to Portrait.")
        } else {
            logger.warning("    [Orientation] Could not determine top view controller. Locking to Portrait as fallback.")
        }
        
        // Default to portrait only
        logger.info("    [Orientation] Defaulting to Portrait only.")
        return .portrait
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
