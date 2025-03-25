import UIKit
import SwiftUI

/// A UIViewController that restricts orientation and hosts the camera preview
class OrientationFixViewController: UIViewController {
    private let contentView: UIView
    fileprivate(set) var allowsLandscape: Bool
    private var hasAppliedInitialOrientation = false
    
    init(contentView: UIView, allowsLandscape: Bool = false) {
        self.contentView = contentView
        self.allowsLandscape = allowsLandscape
        super.init(nibName: nil, bundle: nil)
        
        // Set presentation style to full screen if allowing landscape
        if allowsLandscape {
            self.modalPresentationStyle = .fullScreen
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Add the content view
        view.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // Apply orientation settings
        if !allowsLandscape {
            enforcePortraitOrientation()
            print("DEBUG: OrientationFixViewController loaded - enforcing portrait orientation")
        } else {
            // If we allow landscape, explicitly enable landscape orientation
            enableAllOrientations()
            print("DEBUG: OrientationFixViewController loaded - allowing landscape orientation")
            
            // Also set the AppDelegate flag
            AppDelegate.isVideoLibraryPresented = true
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        if !allowsLandscape {
            // Always force portrait orientation
            enforcePortraitOrientation()
        } else {
            // When allowing landscape, make sure to update to current device orientation
            if !hasAppliedInitialOrientation {
                hasAppliedInitialOrientation = true
                updateToCurrentDeviceOrientation()
                
                // Also set the AppDelegate flag
                AppDelegate.isVideoLibraryPresented = true
            }
        }
        
        // Modern approach to update orientation
        self.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if allowsLandscape {
            // Force device to consider rotating when view appears
            AppDelegate.isVideoLibraryPresented = true
            
            // Use a slight delay to ensure the view has fully appeared
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Ensure we're still in landscape mode by using setNeedsUpdateOfSupportedInterfaceOrientations
                // which is the modern replacement for attemptRotationToDeviceOrientation
                self.setNeedsUpdateOfSupportedInterfaceOrientations()
                
                // Also notify others that might need to update
                if let windowScene = self.findActiveWindowScene() {
                    for window in windowScene.windows {
                        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    }
                }
                
                // Post notification for orientation change
                NotificationCenter.default.post(
                    name: UIDevice.orientationDidChangeNotification,
                    object: nil
                )
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // If this is a landscape-allowed view, reset to portrait when it disappears
        // but only if it's not being replaced by another landscape view
        if allowsLandscape && !AppDelegate.isVideoLibraryPresented {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !AppDelegate.isVideoLibraryPresented {
                    self.enforcePortraitOrientation()
                }
            }
        }
    }
    
    // Helper method to enforce portrait orientation using modern API
    private func enforcePortraitOrientation() {
        // Find the active window scene
        if let windowScene = findActiveWindowScene() ?? view.window?.windowScene {
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .portrait)
            windowScene.requestGeometryUpdate(geometryPreferences) { error in
                print("DEBUG: Portrait orientation applied: \(error.localizedDescription)")
            }
            
            // Also update all view controllers
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
    
    // Helper method to enable all orientations
    private func enableAllOrientations() {
        if let windowScene = findActiveWindowScene() ?? view.window?.windowScene {
            let orientations: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
            windowScene.requestGeometryUpdate(geometryPreferences) { error in
                print("DEBUG: All orientations enabled: \(error.localizedDescription)")
            }
            
            // Also update all view controllers
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
    
    // Update to match current device orientation
    private func updateToCurrentDeviceOrientation() {
        let currentOrientation = UIDevice.current.orientation
        
        if let windowScene = findActiveWindowScene() ?? view.window?.windowScene {
            var preferredOrientations: UIInterfaceOrientationMask
            var targetOrientation: UIInterfaceOrientation?
            
            if currentOrientation.isLandscape {
                print("DEBUG: OrientationFixVC adapting to landscape orientation: \(currentOrientation.rawValue)")
                preferredOrientations = [.portrait, .landscapeLeft, .landscapeRight]
                
                // Map device orientation to interface orientation
                if currentOrientation == .landscapeLeft {
                    targetOrientation = .landscapeRight
                } else if currentOrientation == .landscapeRight {
                    targetOrientation = .landscapeLeft
                }
            } else if currentOrientation == .faceUp || currentOrientation == .faceDown {
                print("DEBUG: OrientationFixVC handling face up/down orientation: \(currentOrientation.rawValue)")
                
                // If we allow landscape and video library is presented, maintain landscape
                if allowsLandscape && AppDelegate.isVideoLibraryPresented {
                    preferredOrientations = [.portrait, .landscapeLeft, .landscapeRight]
                    
                    // Check current interface orientation
                    let currentInterfaceOrientation = windowScene.interfaceOrientation
                    if currentInterfaceOrientation.isLandscape {
                        // Maintain current landscape orientation
                        targetOrientation = currentInterfaceOrientation
                        print("DEBUG: OrientationFixVC maintaining landscape interface orientation: \(currentInterfaceOrientation.rawValue)")
                    } else {
                        // Default to landscape right
                        targetOrientation = .landscapeRight
                        print("DEBUG: OrientationFixVC defaulting to landscape right for face orientation")
                    }
                } else {
                    // Default to portrait in other cases
                    preferredOrientations = .portrait
                    targetOrientation = .portrait
                }
            } else {
                // Default to all orientations allowed if we allow landscape
                if allowsLandscape {
                    preferredOrientations = [.portrait, .landscapeLeft, .landscapeRight]
                } else {
                    preferredOrientations = .portrait
                    targetOrientation = .portrait
                }
            }
            
            // Apply orientation mask
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: preferredOrientations)
            windowScene.requestGeometryUpdate(geometryPreferences) { error in
                print("DEBUG: OrientationFixVC orientation adaptation complete: \(error.localizedDescription)")
            }
            
            // If we have a specific target orientation, set it explicitly
            if let targetOrientation = targetOrientation {
                // Create proper mask from single orientation
                let orientationMask: UIInterfaceOrientationMask
                switch targetOrientation {
                case .portrait: orientationMask = .portrait
                case .portraitUpsideDown: orientationMask = .portraitUpsideDown
                case .landscapeLeft: orientationMask = .landscapeLeft
                case .landscapeRight: orientationMask = .landscapeRight
                default: orientationMask = .portrait
                }
                
                let specificGeometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientationMask)
                windowScene.requestGeometryUpdate(specificGeometryPreferences) { error in
                    print("DEBUG: OrientationFixVC specific orientation update: \(error.localizedDescription)")
                }
            }
            
            // Also update all view controllers
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
    
    // Only allow portrait orientation or both based on setting
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        // If the video library flag is set in AppDelegate, always return all orientations
        if AppDelegate.isVideoLibraryPresented {
            return [.portrait, .landscapeLeft, .landscapeRight]
        }
        
        // Otherwise use the local property
        return allowsLandscape ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
    }
    
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        // If we allow landscape and the current orientation is landscape, match it
        if (allowsLandscape || AppDelegate.isVideoLibraryPresented) && UIDevice.current.orientation.isLandscape {
            // Map device orientation to interface orientation
            // Note that UIDeviceOrientation.landscapeLeft maps to UIInterfaceOrientation.landscapeRight and vice versa
            return UIDevice.current.orientation == .landscapeLeft ? .landscapeRight : .landscapeLeft
        }
        
        // Default to portrait
        return .portrait
    }
    
    override var shouldAutorotate: Bool {
        return allowsLandscape || AppDelegate.isVideoLibraryPresented
    }
}

// Extension to make this available in SwiftUI
extension UIViewController {
    // Helper method to find the current active window scene
    func findActiveWindowScene() -> UIWindowScene? {
        return UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first
    }
}

// MARK: - SwiftUI Integration

/// A SwiftUI wrapper for the orientation fix view controller
struct OrientationFixView<Content: View>: UIViewControllerRepresentable {
    var content: Content
    var allowsLandscape: Bool
    
    init(allowsLandscape: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.allowsLandscape = allowsLandscape
        
        // Set AppDelegate flag if we're initializing with landscape allowed
        if allowsLandscape {
            AppDelegate.isVideoLibraryPresented = true
        }
    }
    
    func makeUIViewController(context: Context) -> OrientationFixViewController {
        // Create a hosting controller for the SwiftUI content
        let hostingController = UIHostingController(rootView: content)
        
        // Extract the UIView from the hosting controller
        let contentView = hostingController.view!
        contentView.backgroundColor = .clear
        
        // Create and return the orientation fix view controller
        return OrientationFixViewController(contentView: contentView, allowsLandscape: allowsLandscape)
    }
    
    func updateUIViewController(_ uiViewController: OrientationFixViewController, context: Context) {
        // If we allow landscape, ensure orientation is updated
        if allowsLandscape {
            AppDelegate.isVideoLibraryPresented = true
            uiViewController.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
} 