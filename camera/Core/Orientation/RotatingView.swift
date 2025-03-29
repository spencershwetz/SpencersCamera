import SwiftUI
import UIKit

struct RotatingView<Content: View>: UIViewControllerRepresentable {
    let content: Content
    @ObservedObject var orientationViewModel: DeviceOrientationViewModel
    let invertRotation: Bool
    
    init(orientationViewModel: DeviceOrientationViewModel, invertRotation: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self._orientationViewModel = ObservedObject(wrappedValue: orientationViewModel)
        self.invertRotation = invertRotation
    }
    
    func makeUIViewController(context: Context) -> RotatingViewController<Content> {
        return RotatingViewController(rootView: content, orientationViewModel: orientationViewModel, invertRotation: invertRotation)
    }
    
    func updateUIViewController(_ uiViewController: RotatingViewController<Content>, context: Context) {
        uiViewController.updateContent(content)
        uiViewController.updateOrientation(orientationViewModel.orientation)
    }
}

class RotatingViewController<Content: View>: UIViewController {
    private var hostingController: UIHostingController<Content>
    private var orientationViewModel: DeviceOrientationViewModel
    private var invertRotation: Bool
    
    init(rootView: Content, orientationViewModel: DeviceOrientationViewModel, invertRotation: Bool) {
        self.hostingController = UIHostingController(rootView: rootView)
        self.orientationViewModel = orientationViewModel
        self.invertRotation = invertRotation
        super.init(nibName: nil, bundle: nil)
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
        var transform: CGAffineTransform = .identity
        
        switch orientation {
        case .landscapeLeft:
            transform = CGAffineTransform(rotationAngle: invertRotation ? CGFloat.pi / 2 : -CGFloat.pi / 2)
        case .landscapeRight:
            transform = CGAffineTransform(rotationAngle: invertRotation ? -CGFloat.pi / 2 : CGFloat.pi / 2)
        case .portraitUpsideDown:
            transform = CGAffineTransform(rotationAngle: CGFloat.pi)
        default:
            transform = .identity
        }
        
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.3) {
                self.hostingController.view.transform = transform
            }
        }
    }
} 