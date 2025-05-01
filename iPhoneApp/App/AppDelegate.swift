import UIKit
import SwiftUI
import AVFoundation
import os.log

/// Main application delegate that handles orientation locking and other app-level functionality
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    // Logger for AppDelegate
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "AppDelegate")

    // MARK: - Orientation Lock Properties
    
    /// Static variable to track view controllers that need landscape support
    static var landscapeEnabledViewControllers: [String] = []
    
    // Track whether status bar should be hidden
    static var shouldHideStatusBar: Bool = true
    
    // MARK: - Application Lifecycle
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Configure AVAudioSession
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording)
            try AVAudioSession.sharedInstance().setActive(true)
            logger.info("Successfully configured AVAudioSession")
        } catch {
            logger.error("Failed to configure AVAudioSession: \(error.localizedDescription)")
        }
        
        // Request camera permissions early
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted {
                self.logger.info("Camera access granted")
            } else {
                self.logger.error("Camera access denied")
            }
        }
        
        // Request microphone permissions early
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                self.logger.info("Microphone access granted")
            } else {
                self.logger.error("Microphone access denied")
            }
        }
        
        #if canImport(DockKit)
        if #available(iOS 18.0, *) {
            // Initialize DockKit early if available
            logger.info("iOS 18.0+ detected, DockKit initialization available")
        }
        #endif
        
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
        // logger.debug("Querying supported interface orientations.")
        // Get the top view controller
        if let topViewController = window?.rootViewController?.topMostViewController() {
            let vcName = String(describing: type(of: topViewController))
            // logger.debug("Top view controller identified: \(vcName)")
            
            // Check if this is a presentation controller that contains our view
            if vcName.contains("PresentationHostingController") {
                // For SwiftUI presentation controllers, we need to check their content
                if let childController = topViewController.children.first {
                    let childName = String(describing: type(of: childController))
                    // logger.debug("PresentationHostingController contains child: \(childName)")
                    
                    // Check if the child controller is allowed to use landscape
                    if AppDelegate.landscapeEnabledViewControllers.contains(where: { childName.contains($0) }) {
                        // logger.info("Child controller \(childName) allows landscape. Allowing Portrait and Landscape Left/Right.")
                        return [.portrait, .landscapeLeft, .landscapeRight]
                    } else {
                        // logger.info("Child controller \(childName) does not require landscape. Locking to Portrait.")
                        return .portrait
                    }
                } else {
                    // logger.warning("PresentationHostingController has no children. Locking to Portrait.")
                    return .portrait
                }
            }
            
            // Check if the current view controller allows landscape
            if let orientationViewController = topViewController as? OrientationFixViewController {
                // Use property from our custom view controller
                if orientationViewController.allowsLandscapeMode {
                    // logger.info("OrientationFixViewController allows landscape. Allowing Portrait and Landscape Left/Right.")
                    return [.portrait, .landscapeLeft, .landscapeRight]
                }
            }
            
            // Check the VC name against our list
            if AppDelegate.landscapeEnabledViewControllers.contains(where: { vcName.contains($0) }) {
                logger.info("    [Orientation] Top VC '\(vcName)' allows landscape via static list. Allowing All.")
                return [.portrait, .landscapeLeft, .landscapeRight]
            }
            
            // logger.info("    [Orientation] No special case matched for VC '\(vcName)'. Locking to Portrait.")
        } else {
            logger.warning("    [Orientation] Could not determine top view controller. Locking to Portrait as fallback.")
        }
        
        // Default to portrait only
        // logger.info("    [Orientation] Defaulting to Portrait only.")
        return .portrait
    }
    
    // MARK: UISceneSession Lifecycle
    
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
    
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        logger.info("Scene sessions discarded")
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
