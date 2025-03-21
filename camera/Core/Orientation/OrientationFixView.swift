import UIKit
import SwiftUI

/// A UIViewController that allows system UI rotation while app content can be locked
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
        
        print("⚠️ OrientationFixViewController loaded - This allows SYSTEM UI to rotate")
        print("⚠️ Current orientation mask: \(AppDelegate.orientationLock)")
        print("⚠️ App content will still be locked to portrait via PortraitFixedContainer")
        
        // Register for rotation notifications to track when they happen
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationWillChange),
            name: UIApplication.willChangeStatusBarOrientationNotification,
            object: nil
        )
    }
    
    @objc func orientationWillChange(_ notification: Notification) {
        if let orientation = notification.userInfo?[UIApplication.statusBarOrientationUserInfoKey] as? Int {
            print("⚠️ SYSTEM UI ROTATION - New orientation: \(orientation)")
            print("📏 VIEW BOUNDS - Bounds: \(view.bounds), Frame: \(view.frame)")
            print("📏 CONTENT BOUNDS - Bounds: \(contentView.bounds), Frame: \(contentView.frame)")
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Allow all orientations for SYSTEM UI only
        AppDelegate.orientationLock = .all
        print("⚠️ OrientationFixViewController set AppDelegate.orientationLock to ALL (for system UI)")
        
        // Modern approach to update orientation
        self.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Maintain orientation freedom when view disappears
        AppDelegate.orientationLock = .all
    }
    
    // Allow all orientations for SYSTEM UI
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }
    
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .portrait  // Default to portrait for initial presentation only
    }
    
    override var shouldAutorotate: Bool {
        return true  // Allow system UI autorotation
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
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
        
        print("⚠️ OrientationFixView created - This will allow ALL orientations")
        
        // Create and return the orientation fix view controller
        return OrientationFixViewController(contentView: contentView)
    }
    
    func updateUIViewController(_ uiViewController: OrientationFixViewController, context: Context) {
        // Nothing to update
    }
} 