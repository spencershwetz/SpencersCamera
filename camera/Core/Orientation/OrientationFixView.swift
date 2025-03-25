import UIKit
import SwiftUI

/// A UIViewController that restricts orientation and hosts the camera preview
class OrientationFixViewController: UIViewController {
    private let contentView: UIView
    fileprivate(set) var allowsLandscape: Bool
    
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
            updateToCurrentDeviceOrientation()
            
            // Also set the AppDelegate flag
            AppDelegate.isVideoLibraryPresented = true
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
                UIViewController.attemptRotationToDeviceOrientation()
                
                // Also try using the notification center to force rotation
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
                    // Reset to portrait orientation
                    if let windowScene = self.view.window?.windowScene {
                        let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .portrait)
                        windowScene.requestGeometryUpdate(geometryPreferences) { error in
                            print("DEBUG: Error resetting to portrait: \(error.localizedDescription)")
                        }
                    }
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
                // The error parameter here is not optional, it's a concrete Error
                print("DEBUG: Error enforcing portrait orientation: \(error.localizedDescription)")
            }
        }
    }
    
    // Helper method to enable all orientations
    private func enableAllOrientations() {
        if let windowScene = findActiveWindowScene() ?? view.window?.windowScene {
            let orientations: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
            windowScene.requestGeometryUpdate(geometryPreferences) { error in
                print("DEBUG: Error enabling all orientations: \(error.localizedDescription)")
            }
        }
    }
    
    // Update to match current device orientation
    private func updateToCurrentDeviceOrientation() {
        let currentOrientation = UIDevice.current.orientation
        if currentOrientation.isLandscape {
            print("DEBUG: Adapting to landscape orientation: \(currentOrientation.rawValue)")
            
            if let windowScene = findActiveWindowScene() ?? view.window?.windowScene {
                let orientations: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
                let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
                windowScene.requestGeometryUpdate(geometryPreferences) { error in
                    print("DEBUG: Error adapting to landscape: \(error.localizedDescription)")
                }
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
            .first as? UIWindowScene
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
        // If we allow landscape, attempt rotation when updating
        if allowsLandscape {
            AppDelegate.isVideoLibraryPresented = true
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
} 