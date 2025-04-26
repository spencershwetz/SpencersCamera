import UIKit
import SwiftUI
import AVFoundation
import os.log

/// Main application delegate that handles orientation locking and other app-level functionality
class AppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "com.camera", category: "AppDelegate")
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        logger.info("Application launching...")
        
        // Configure audio session
        configureAudioSession()
        
        // Request camera permissions early
        AVCaptureDevice.requestAccess(for: .video) { granted in
            self.logger.info("Camera permission status: \(granted)")
        }
        
        // Enable background audio
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, 
                                                        options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
        
        // Register for notifications
        registerForNotifications()
        
        return true
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        logger.info("Application will resign active")
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        logger.info("Application did enter background")
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        logger.info("Application will enter foreground")
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        logger.info("Application did become active")
    }
    
    // MARK: - Private Methods
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, 
                                       mode: .videoRecording,
                                       options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
            try audioSession.setActive(true)
            logger.info("Audio session configured successfully")
        } catch {
            logger.error("Failed to configure audio session: \(error.localizedDescription)")
        }
    }
    
    private func registerForNotifications() {
        // Register for necessary notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }
    
    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            logger.info("Audio session interruption began")
        case .ended:
            logger.info("Audio session interruption ended")
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    try? AVAudioSession.sharedInstance().setActive(true)
                }
            }
        @unknown default:
            logger.error("Unknown audio session interruption type")
        }
    }
    
    @objc private func handleAudioRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable:
            logger.info("Audio route changed: New device available")
        case .oldDeviceUnavailable:
            logger.info("Audio route changed: Old device unavailable")
        default:
            logger.debug("Audio route changed: \(reason.rawValue)")
        }
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
