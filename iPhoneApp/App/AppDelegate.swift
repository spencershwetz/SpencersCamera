import UIKit
import SwiftUI
import os.log
import AVFoundation
import Photos

/// Main application delegate that handles orientation locking and other app-level functionality
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    // Logger for AppDelegate
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "AppDelegateOrientation")
    
    // MARK: - Properties
    
    private var isFirstLaunch = true
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isTransitioningState = false
    private let stateQueue = DispatchQueue(label: "com.spencerscamera.stateTransition")
    private var lastActiveState: UIApplication.State = .inactive
    
    // MARK: - Orientation Lock Properties
    static var landscapeEnabledViewControllers: [String] = []
    static var shouldHideStatusBar: Bool = true
    
    // MARK: - Application Lifecycle
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        logger.info("Setting up AppDelegate for iOS 18+")
        setupNotificationObservers()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        setupAudioSession()
        requestPermissions()
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isTransitioningState else { return }
            
            self.isTransitioningState = true
            self.logger.info("App entering background - deactivating audio session")
            
            // End existing background task if any
            self.endBackgroundTask()
            
            // Start new background task
            self.backgroundTask = application.beginBackgroundTask { [weak self] in
                self?.endBackgroundTask()
            }
            
            // Deactivate audio session
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                self.logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
            }
            
            self.cleanupResources()
            self.lastActiveState = .background
            self.isTransitioningState = false
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isTransitioningState else { return }
            
            self.isTransitioningState = true
            self.logger.info("App entering foreground - reactivating audio session")
            
            // Wait briefly to ensure background cleanup is complete
            Thread.sleep(forTimeInterval: 0.1)
            
            self.setupAudioSession()
            self.endBackgroundTask()
            self.lastActiveState = .active
            self.isTransitioningState = false
        }
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isTransitioningState else { return }
            
            if self.isFirstLaunch {
                self.requestPermissions()
                self.isFirstLaunch = false
            }
            
            self.lastActiveState = .active
        }
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.logger.info("App terminating - cleaning up resources")
            self.cleanupResources()
            NotificationCenter.default.removeObserver(self)
            self.endBackgroundTask()
        }
    }
    
    // MARK: - Private Methods
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    private func cleanupResources() {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        
        // Ensure audio session deactivation is done safely
        do {
            if AVAudioSession.sharedInstance().isOtherAudioPlaying {
                try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            } else {
                try AVAudioSession.sharedInstance().setActive(false)
            }
        } catch {
            logger.error("Failed to deactivate audio session during cleanup: \(error.localizedDescription)")
        }
    }
    
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    
    @objc private func handleMemoryWarning() {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.logger.warning("Received memory warning - cleaning up resources")
            self.cleanupResources()
        }
    }
    
    // MARK: - Setup Methods
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            try audioSession.setCategory(.playAndRecord,
                                      mode: .videoRecording,
                                      options: [.allowBluetooth,
                                              .allowBluetoothA2DP,
                                              .mixWithOthers,
                                              .defaultToSpeaker])
            
            try audioSession.setPreferredSampleRate(48000.0)
            try audioSession.setPreferredIOBufferDuration(0.005)
            
            if let preferredInput = audioSession.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try audioSession.setPreferredInput(preferredInput)
            }
            
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            logger.info("Audio session configured successfully")
        } catch {
            logger.error("Failed to configure audio session: \(error.localizedDescription)")
        }
    }
    
    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            self?.logger.info("Camera permission \(granted ? "granted" : "denied")")
        }
        
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            self?.logger.info("Microphone permission \(granted ? "granted" : "denied")")
        }
        
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            self?.logger.info("Photos permission status: \(status.rawValue)")
        }
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
