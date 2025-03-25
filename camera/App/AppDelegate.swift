import UIKit
import SwiftUI

/// Main application delegate that handles orientation locking and other app-level functionality
class AppDelegate: NSObject, UIApplicationDelegate {
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
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Register for device orientation notifications
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        // Setup orientation lock observer
        UIWindowScene.setupOrientationLockSupport()
        
        // Add notification observer for orientation debugging
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            let orientation = UIDevice.current.orientation
            print("🔄 AppDelegate detected orientation change: \(orientation.rawValue)")
            
            // Force attempt rotation when orientation changes
            if AppDelegate.isVideoLibraryPresented && orientation.isLandscape {
                DispatchQueue.main.async {
                    UIViewController.attemptRotationToDeviceOrientation()
                }
            }
        }
        
        return true
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        // Stop device orientation notifications to clean up
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
    
    // MARK: - Orientation Support
    
    /// Handle orientation lock dynamically based on the current view controller
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // If video library is flagged as presented, always allow landscape
        if AppDelegate.isVideoLibraryPresented {
            print("DEBUG: AppDelegate allowing landscape for video library")
            return [.portrait, .landscapeLeft, .landscapeRight]
        }
        
        // Get the top view controller
        if let topViewController = window?.rootViewController?.topMostViewController() {
            let vcName = String(describing: type(of: topViewController))
            
            // Check if this is a presentation controller that contains our view
            if vcName.contains("PresentationHostingController") {
                // For SwiftUI presentation controllers, we need to check their content
                if let childController = topViewController.children.first {
                    let childName = String(describing: type(of: childController))
                    print("DEBUG: PresentationHostingController contains: \(childName)")
                    
                    // If the child name contains any of our landscape enabled controllers, allow landscape
                    if AppDelegate.landscapeEnabledViewControllers.contains(where: { childName.contains($0) }) {
                        print("DEBUG: AppDelegate allowing landscape for child: \(childName)")
                        return [.portrait, .landscapeLeft, .landscapeRight]
                    }
                }
                
                // If we can't determine the content, check if it's a full screen presentation
                if topViewController.modalPresentationStyle == .fullScreen {
                    print("DEBUG: AppDelegate allowing landscape for full screen presentation")
                    return [.portrait, .landscapeLeft, .landscapeRight]
                }
            }
            
            // Check if the current view controller allows landscape
            if let orientationViewController = topViewController as? OrientationFixViewController {
                // Use property from our custom view controller
                if orientationViewController.allowsLandscapeMode {
                    print("DEBUG: AppDelegate allowing landscape for OrientationFixViewController")
                    return [.portrait, .landscapeLeft, .landscapeRight]
                }
            }
            
            // Check the VC name against our list
            if AppDelegate.landscapeEnabledViewControllers.contains(where: { vcName.contains($0) }) {
                print("DEBUG: AppDelegate allowing landscape for \(vcName)")
                return [.portrait, .landscapeLeft, .landscapeRight]
            }
            
            print("DEBUG: AppDelegate enforcing portrait for \(vcName)")
        }
        
        // Default to portrait only
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

// MARK: - Make allowsLandscape property public
extension OrientationFixViewController {
    var allowsLandscapeMode: Bool {
        return self.allowsLandscape
    }
} 