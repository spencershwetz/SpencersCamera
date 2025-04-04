import SwiftUI
import UIKit
import Combine
import os.log

/// A SwiftUI view that wraps a UIHostingController to allow its content to rotate with the device orientation.
struct RotatingView<Content: View>: UIViewControllerRepresentable {
    let content: Content
    @ObservedObject var orientationViewModel: DeviceOrientationViewModel
    let invertRotation: Bool
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "RotatingView")
    
    init(orientationViewModel: DeviceOrientationViewModel, invertRotation: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self._orientationViewModel = ObservedObject(wrappedValue: orientationViewModel)
        self.invertRotation = invertRotation
        logger.info("Initializing RotatingView. InvertRotation: \\(invertRotation)")
    }
    
    func makeUIViewController(context: Context) -> RotatingViewController<Content> {
        let controller = RotatingViewController(rootView: content, orientationViewModel: orientationViewModel, invertRotation: invertRotation)
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        
        // Set initial transform based on current orientation
        controller.updateOrientation(UIDevice.current.orientation)
        logger.info("RotatingViewController created. Initial orientation set.")
        return controller
    }
    
    func updateUIViewController(_ uiViewController: RotatingViewController<Content>, context: Context) {
        uiViewController.updateContent(content)
        uiViewController.updateOrientation(orientationViewModel.orientation)
    }
}

class RotatingViewController<Content: View>: UIViewController {
    private var cancellables = Set<AnyCancellable>()
    private let orientationViewModel = DeviceOrientationViewModel.shared
    private var hostingController: UIHostingController<Content>!
    private let invertRotation: Bool
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "RotatingView.Controller")
    
    init(rootView: Content, orientationViewModel: DeviceOrientationViewModel, invertRotation: Bool) {
        self.invertRotation = invertRotation
        super.init(nibName: nil, bundle: nil)
        hostingController = UIHostingController(rootView: rootView)
        hostingController.view.backgroundColor = .clear
        logger.info("RotatingViewController init. InvertRotation: \\(invertRotation)")
        
        // Use the shared orientation view model
        orientationViewModel.$orientation
            .receive(on: RunLoop.main)
            .sink { [weak self] newOrientation in
                self?.logger.info("Received new orientation from ViewModel: \\(newOrientation.rawValue)")
                self?.updateOrientation(newOrientation)
            }
            .store(in: &cancellables)
        logger.info("Subscribed to orientation changes.")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupHostingController()
    }
    
    private func setupHostingController() {
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }
    
    func updateContent(_ newContent: Content) {
        hostingController.rootView = newContent
    }
    
    func updateOrientation(_ orientation: UIDeviceOrientation) {
        logger.info("Updating UI transform for orientation: \\(orientation.rawValue) - \\(String(describing: orientation)). Invert: \\(invertRotation)")
        var transform: CGAffineTransform = .identity
        var angleDegrees: CGFloat = 0
        
        switch orientation {
        case .landscapeLeft:
            transform = CGAffineTransform(rotationAngle: invertRotation ? CGFloat.pi / 2 : -CGFloat.pi / 2)
            angleDegrees = invertRotation ? 90 : -90
        case .landscapeRight:
            transform = CGAffineTransform(rotationAngle: invertRotation ? -CGFloat.pi / 2 : CGFloat.pi / 2)
            angleDegrees = invertRotation ? -90 : 90
        case .portraitUpsideDown:
            transform = CGAffineTransform(rotationAngle: CGFloat.pi)
            angleDegrees = 180
        default: // .portrait, .unknown, .faceUp, .faceDown
            transform = .identity
            angleDegrees = 0
        }
        
        logger.info("Applying transform for \\(orientation.rawValue): Rotation \\(angleDegrees) degrees.")
        UIView.animate(withDuration: 0.3) {
            self.hostingController.view.transform = transform
        }
    }
} 