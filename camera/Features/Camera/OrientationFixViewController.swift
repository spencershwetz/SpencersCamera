import UIKit
import SwiftUI

/// A UIViewController that restricts orientation and hosts the camera preview
class OrientationFixViewController: UIViewController {
    private let contentView: UIView
    
    init(contentView: UIView) {
        self.contentView = contentView
        super.init(nibName: nil, bundle: nil)
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
        
        // Apply orientation lock
        UIDevice.current.setValue(UIDeviceOrientation.portrait.rawValue, forKey: "orientation")
        
        print("DEBUG: OrientationFixViewController loaded - enforcing portrait orientation")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Force portrait orientation
        AppDelegate.orientationLock = .portrait
        
        // Apply orientation lock on appearance
        UIDevice.current.setValue(UIDeviceOrientation.portrait.rawValue, forKey: "orientation")
        
        // Notify the system to update orientation
        UIViewController.attemptRotationToDeviceOrientation()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Release orientation lock when view disappears
        AppDelegate.orientationLock = .all
    }
    
    // Only allow portrait orientation
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }
    
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .portrait
    }
    
    override var shouldAutorotate: Bool {
        return false
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
    
    func makeUIViewController(context: Context) -> OrientationFixViewController {
        // Create a hosting controller for the SwiftUI content
        let hostingController = UIHostingController(rootView: content)
        
        // Extract the UIView from the hosting controller
        let contentView = hostingController.view!
        contentView.backgroundColor = .clear
        
        // Create and return the orientation fix view controller
        return OrientationFixViewController(contentView: contentView)
    }
    
    func updateUIViewController(_ uiViewController: OrientationFixViewController, context: Context) {
        // Nothing to update
    }
}

// Extension for AppDelegate to control orientation
extension AppDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}

// We need to have an AppDelegate class if it doesn't exist already
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        return true
    }
} 