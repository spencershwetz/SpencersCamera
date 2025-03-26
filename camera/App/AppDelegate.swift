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
        "PresentationHostingController"
    ]
    
    // Track if the video library is currently being presented
    static var isVideoLibraryPresented: Bool = false
    
    // MARK: - Application Lifecycle
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        print("DEBUG: AppDelegate - Application launching")
        
        // Force dark mode at UIApplication level
        if #available(iOS 13.0, *) {
            window?.overrideUserInterfaceStyle = .dark
            UIApplication.shared.windows.forEach { window in
                window.overrideUserInterfaceStyle = .dark
                
                // Disable safe area insets for all windows
                window.rootViewController?.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)
            }
        }
        
        // Create and configure window
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = .black
        
        // Configure root view controller
        let contentView = ContentView()
        let hostingController = UIHostingController(rootView: contentView)
        hostingController.view.backgroundColor = .black
        
        // Force dark mode for view controller
        hostingController.overrideUserInterfaceStyle = .dark
        
        // Set modal presentation style
        hostingController.modalPresentationStyle = .overFullScreen
        
        // Disable safe area insets completely
        hostingController.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)
        hostingController.view.frame = UIScreen.main.bounds
        
        // Set window properties
        window?.rootViewController = hostingController
        window?.makeKeyAndVisible()
        
        // Disable safe area insets at window level again
        window?.rootViewController?.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)
        
        // Force dark mode again after window is visible
        window?.overrideUserInterfaceStyle = .dark
        
        // Force black backgrounds
        if let rootView = window?.rootViewController?.view {
            forceBlackBackgrounds(rootView)
        }
        
        // Inspect view hierarchy colors
        inspectViewHierarchyBackgroundColors(hostingController.view)
        
        // Register for device orientation notifications
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        // Setup orientation lock observer
        UIWindowScene.setupOrientationLockSupport()
        
        // Remove debug observer for orientation
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        
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
                    
                    // Check if any child view controller supports landscape orientation
                    for controller in topViewController.children {
                        let controllerName = String(describing: type(of: controller))
                        if AppDelegate.landscapeEnabledViewControllers.contains(where: { controllerName.contains($0) }) {
                            print("DEBUG: AppDelegate allowing landscape for child: \(controllerName)")
                            return [.portrait, .landscapeLeft, .landscapeRight]
                        }
                    }
                    
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

// MARK: - UIWindow Extension
extension UIWindow {
    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Force dark mode when traits change
        if #available(iOS 13.0, *) {
            self.overrideUserInterfaceStyle = .dark
        }
    }
}
