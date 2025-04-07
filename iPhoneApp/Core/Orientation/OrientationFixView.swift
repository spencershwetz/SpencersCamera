import UIKit
import SwiftUI

/// A UIViewController that hosts the camera preview (orientation managed by SwiftUI modifiers)
class OrientationFixViewController: UIViewController {
    private let contentView: UIView
    private var hasAppliedInitialOrientation = false
    
    init(rootView: UIView) {
        self.contentView = rootView
        super.init(nibName: nil, bundle: nil)
        
        // Set black background color
        self.view.backgroundColor = .black
        
        self.modalPresentationStyle = .fullScreen
        print("DEBUG: OrientationFixViewController initializing")
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
        
        // Set black background for all parent views up the hierarchy
        setBlackBackgroundForAllParentViews()
        
        print("DEBUG: OrientationFixViewController viewDidLoad - background set to black")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Set background to black
        view.backgroundColor = .black
        
        enforcePortraitOrientation()
        print("DEBUG: OrientationFixViewController viewWillAppear - enforcing portrait mode")
        
        // Set black background for all parent views
        setBlackBackgroundForAllParentViews()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Set black background for all parent views again after appearing
        setBlackBackgroundForAllParentViews()
        
        // Apply orientation settings again after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.enforcePortraitOrientation()
        }
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        
        // Force black background during layout
        view.backgroundColor = .black
        setBlackBackgroundForAllParentViews()
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
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        // Always return portrait as this ViewController hosts the main camera UI
        return .portrait
    }
    
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .portrait
    }
    
    private func setBlackBackgroundForAllParentViews() {
        // Recursively set black background color on all parent views
        var currentView: UIView? = self.view
        while let view = currentView {
            view.backgroundColor = .black
            currentView = view.superview
        }
        
        // Also ensure all window backgrounds are black
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.backgroundColor = .black }
        
        print("DEBUG: Set black background for all parent views")
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
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
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
        return OrientationFixViewController(rootView: contentView)
    }
    
    func updateUIViewController(_ uiViewController: OrientationFixViewController, context: Context) {
        // REMOVED: No updates needed here anymore based on landscape mode.
        // The SwiftUI .supportedInterfaceOrientations modifier handles allowed orientations.
        /*
        // If we allow landscape, ensure orientation is updated
        if allowsLandscapeMode {
            AppDelegate.isVideoLibraryPresented = true
            uiViewController.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        */
    }
} 