import UIKit
import SwiftUI

/// Main application delegate that handles orientation locking and other app-level functionality
class AppDelegate: NSObject, UIApplicationDelegate {
    // MARK: - Orientation Lock Properties
    
    /// Current orientation lock state for the app - now hardcoded to portrait only
    static var orientationLock = UIInterfaceOrientationMask.portrait
    
    // MARK: - Application Lifecycle
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Register for device orientation notifications
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        // Setup orientation lock observer
        UIWindowScene.setupOrientationLockSupport()
        
        return true
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        // Stop device orientation notifications to clean up
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
    
    // MARK: - Orientation Support
    
    /// Handle orientation lock for all windows in the application - always return portrait
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }
} 