import UIKit
import SwiftUI

/// Main application delegate that handles orientation management and other app-level functionality
class AppDelegate: NSObject, UIApplicationDelegate {
    // MARK: - Orientation Properties
    
    /// Current orientation setting for the app
    static var orientationLock = UIInterfaceOrientationMask.all
    
    // MARK: - Application Lifecycle
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Register for device orientation notifications
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        // Setup orientation support
        UIWindowScene.setupOrientationLockSupport()
        
        return true
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        // Stop device orientation notifications to clean up
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
    
    // MARK: - Orientation Support
    
    /// Handle orientation for all windows in the application
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
} 