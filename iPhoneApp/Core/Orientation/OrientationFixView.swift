import UIKit
import SwiftUI

/// A UIViewController that restricts orientation and hosts the camera preview
class OrientationFixViewController: UIViewController {
    private let contentView: UIView
    private(set) var allowsLandscapeMode: Bool
    private var hasAppliedInitialOrientation = false
    
    init(rootView: UIView, allowLandscape: Bool = false) {
        self.contentView = rootView
        self.allowsLandscapeMode = allowLandscape
        super.init(nibName: nil, bundle: nil)
        
        // Set black background color
        self.view.backgroundColor = .black
        
        // Configure modal presentation style based on landscape allowance
        if !allowsLandscapeMode {
            self.modalPresentationStyle = .fullScreen
            print("DEBUG: OrientationFixViewController initializing with portrait-only mode")
        } else {
            print("DEBUG: OrientationFixViewController initializing with all orientations allowed")
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Ensure view background is black
        view.backgroundColor = .black
        
        // Add content view to controller's view
        contentView.frame = view.bounds
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(contentView)
        
        print("DEBUG: OrientationFixViewController viewDidLoad - background set to black")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Set background to black
        view.backgroundColor = .black
        
        // Apply orientation settings
        if !allowsLandscapeMode {
            enforcePortraitOrientation()
            print("DEBUG: OrientationFixViewController viewWillAppear - enforcing portrait mode")
        } else {
            enableAllOrientations()
            print("DEBUG: OrientationFixViewController viewWillAppear - allowing all orientations")
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
    }
    
    private func enforcePortraitOrientation() {
        // Use UIDevice notification-based orientation instead of the unsafe KVC approach
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        // Set preferred orientation via UIApplication
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            if #available(iOS 16.0, *) {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
        
        // Report current orientation settings
        print("DEBUG: Enforcing portrait orientation")
    }
    
    private func enableAllOrientations() {
        // Allow all orientations
        print("DEBUG: Enabling all orientations")
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if allowsLandscapeMode {
            return .all
        } else {
            return .portrait
        }
    }
    
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .portrait
    }
    
    // Hide status bar
    override var prefersStatusBarHidden: Bool {
        return AppDelegate.shouldHideStatusBar
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
    var allowsLandscapeMode: Bool
    
    init(allowsLandscapeMode: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.allowsLandscapeMode = allowsLandscapeMode
        
        // Set AppDelegate flag if we're initializing with landscape allowed
        if allowsLandscapeMode {
            AppDelegate.isVideoLibraryPresented = true
        }
    }
    
    func makeUIViewController(context: Context) -> OrientationFixViewController {
        // Create a hosting controller for the SwiftUI content
        let hostingController = UIHostingController(rootView: content)
        
        // Extract the UIView from the hosting controller
        let contentView = hostingController.view!
        contentView.backgroundColor = .black // Force black background
        
        // Force UIHostingController background to black as well
        hostingController.view.backgroundColor = .black
        
        // Create and return the orientation fix view controller
        return OrientationFixViewController(rootView: contentView, allowLandscape: allowsLandscapeMode)
    }
    
    func updateUIViewController(_ uiViewController: OrientationFixViewController, context: Context) {
        // If we allow landscape, ensure orientation is updated
        if allowsLandscapeMode {
            AppDelegate.isVideoLibraryPresented = true
            uiViewController.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
} 