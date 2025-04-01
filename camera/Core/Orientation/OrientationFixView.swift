import UIKit
import SwiftUI

/// A UIViewController that restricts orientation and hosts the camera preview
class OrientationFixViewController: UIViewController {
    private let contentView: UIView
    private(set) var allowsLandscapeMode: Bool
    private var hasAppliedInitialOrientation = false
    let instanceId = UUID()

    init(rootView: UIView, allowLandscape: Bool = false) {
        self.contentView = rootView
        self.allowsLandscapeMode = allowLandscape
        super.init(nibName: nil, bundle: nil)
        print("🟪 OrientationFixViewController.init() - Instance ID: \(instanceId)")
        self.view.backgroundColor = .black
        if !allowsLandscapeMode {
            self.modalPresentationStyle = .fullScreen
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        
        contentView.frame = view.bounds
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(contentView)
        
        contentView.insetsLayoutMarginsFromSafeArea = false
        additionalSafeAreaInsets = .zero
        
        setBlackBackgroundForAllParentViews()
        
        print("DEBUG: OrientationFixViewController viewDidLoad - background set to black")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        view.backgroundColor = .black
        
        if !allowsLandscapeMode {
            enforcePortraitOrientation()
        } else {
            enableAllOrientations()
        }
        
        setBlackBackgroundForAllParentViews()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        setBlackBackgroundForAllParentViews()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if !self.allowsLandscapeMode {
                self.enforcePortraitOrientation()
            } else {
                self.enableAllOrientations()
            }
        }
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        
        view.backgroundColor = .black
        setBlackBackgroundForAllParentViews()
    }
    
    override var additionalSafeAreaInsets: UIEdgeInsets {
        get {
            return .zero
        }
        set {
            super.additionalSafeAreaInsets = .zero
        }
    }
    
    private func enforcePortraitOrientation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            if #available(iOS 16.0, *) {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
        
        print("DEBUG: Enforcing portrait orientation")
    }
    
    private func enableAllOrientations() {
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
    
    private func setBlackBackgroundForAllParentViews() {
        var currentView: UIView? = self.view
        while let view = currentView {
            view.backgroundColor = .black
            currentView = view.superview
        }
        
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.backgroundColor = .black }
        
        print("DEBUG: Set black background for all parent views")
    }
}

extension UIViewController {
    func findActiveWindowScene() -> UIWindowScene? {
        return UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first
    }
}

// MARK: - SwiftUI Integration

struct OrientationFixView<Content: View>: UIViewControllerRepresentable {
    var content: Content
    var allowsLandscapeMode: Bool
    private let representableInstanceId = UUID()

    init(allowsLandscapeMode: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.allowsLandscapeMode = allowsLandscapeMode
        print("🟧 OrientationFixView.init() - Representable ID: \(representableInstanceId)")
        if allowsLandscapeMode {
            AppDelegate.isVideoLibraryPresented = true
        }
    }

    func makeUIViewController(context: Context) -> OrientationFixViewController {
        print("🟧 OrientationFixView.makeUIViewController - Representable ID: \(representableInstanceId)")
        let hostingController = UIHostingController(rootView: content)
        let contentView = hostingController.view!
        contentView.backgroundColor = .black
        hostingController.view.backgroundColor = .black
        return OrientationFixViewController(rootView: contentView, allowLandscape: allowsLandscapeMode)
    }

    func updateUIViewController(_ uiViewController: OrientationFixViewController, context: Context) {
        print("🟧 OrientationFixView.updateUIViewController - Representable ID: \(representableInstanceId), VC ID: \(uiViewController.instanceId)")
        if allowsLandscapeMode {
            AppDelegate.isVideoLibraryPresented = true
            uiViewController.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
