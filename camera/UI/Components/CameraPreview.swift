import SwiftUI
import AVFoundation

struct FixedOrientationCameraPreview: UIViewRepresentable {
    class VideoPreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }
        
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
        
        // Focus view for tap-to-focus functionality
        let focusView: UIView = {
            let focusView = UIView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
            focusView.layer.borderColor = UIColor.white.cgColor
            focusView.layer.borderWidth = 1.5
            focusView.layer.cornerRadius = 25
            focusView.layer.opacity = 0
            focusView.backgroundColor = .clear
            return focusView
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            
            // Add focus view to the preview view
            addSubview(focusView)
            
            // Register for orientation change notifications
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(orientationChanged),
                name: UIDevice.orientationDidChangeNotification,
                object: nil
            )
            
            // Also register for orientation lock enforcement notifications
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(orientationLockEnforced),
                name: .orientationLockEnforced,
                object: nil
            )
        }
        
        @objc private func orientationChanged() {
            if let connection = videoPreviewLayer.connection {
                // Always lock to portrait orientation regardless of device orientation
                lockToPortraitOrientation(connection)
                print("📱 ORIENTATION CHANGE - Enforcing portrait orientation for camera preview")
                print("📏 FRAME AFTER ORIENTATION CHANGE - Frame: \(frame), Bounds: \(bounds)")
            }
        }
        
        @objc private func orientationLockEnforced() {
            if let connection = videoPreviewLayer.connection {
                // Explicitly lock to portrait when orientation lock is enforced
                lockToPortraitOrientation(connection)
            }
        }
        
        private func updateOrientationForConnection(_ connection: AVCaptureConnection) {
            // Get device orientation for logging only
            let deviceOrientation = UIDevice.current.orientation
            let interfaceOrientation: UIInterfaceOrientation
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                interfaceOrientation = windowScene.interfaceOrientation
            } else {
                interfaceOrientation = .portrait
            }
            
            // Log the current orientations
            print("🔒 LOCKING PREVIEW - Physical Device: \(deviceOrientation.rawValue), Interface: \(interfaceOrientation.rawValue)")
            
            // ALWAYS use portrait orientation (90°) regardless of device/interface orientation
            lockToPortraitOrientation(connection)
        }
        
        private func lockToPortraitOrientation(_ connection: AVCaptureConnection) {
            // Always set to portrait orientation (90°)
            let rotationAngle: CGFloat = 90
            print("🔒 CAMERA PREVIEW - Locked to portrait orientation (90°)")
            
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
                print("✅ Applied portrait rotation angle (90°) to camera preview")
            } else {
                print("⚠️ Rotation angle 90° not supported by connection")
            }
            
            // Adjust the video gravity to ensure content stays within the fixed frame
            videoPreviewLayer.videoGravity = .resizeAspectFill
        }
        
        // Override layoutSubviews to ensure the aspect ratio is preserved during rotation
        override func layoutSubviews() {
            super.layoutSubviews()
            
            // Ensure the video preview layer fills the view
            videoPreviewLayer.frame = bounds
            
            // Ensure the focus view stays centered
            focusView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            
            // Re-lock the orientation whenever the layout changes
            if let connection = videoPreviewLayer.connection {
                lockToPortraitOrientation(connection)
            }
        }
        
        // Support for aspect ratio locking during frame updates
        func updateAspectRatio() {
            // Always lock to portrait orientation regardless of device orientation
            if let connection = videoPreviewLayer.connection {
                lockToPortraitOrientation(connection)
            }
        }
        
        private func describeDeviceOrientation(_ orientation: UIDeviceOrientation) -> String {
            switch orientation {
            case .portrait: return "Portrait"
            case .portraitUpsideDown: return "Portrait Upside Down"
            case .landscapeLeft: return "Landscape Left (home button right)"
            case .landscapeRight: return "Landscape Right (home button left)"
            case .faceUp: return "Face Up"
            case .faceDown: return "Face Down"
            case .unknown: return "Unknown"
            @unknown default: return "Unknown New Case"
            }
        }
        
        private func describeInterfaceOrientation(_ orientation: UIInterfaceOrientation) -> String {
            switch orientation {
            case .portrait: return "Portrait"
            case .portraitUpsideDown: return "Portrait Upside Down"
            case .landscapeLeft: return "Landscape Left (home button left)"
            case .landscapeRight: return "Landscape Right (home button right)"
            case .unknown: return "Unknown"
            @unknown default: return "Unknown New Case"
            }
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
    
    @ObservedObject var viewModel: CameraViewModel
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> VideoPreviewView {
        let viewFinder = VideoPreviewView()
        viewFinder.backgroundColor = .black
        viewFinder.videoPreviewLayer.cornerRadius = 20
        viewFinder.videoPreviewLayer.masksToBounds = true
        viewFinder.videoPreviewLayer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        viewFinder.videoPreviewLayer.borderWidth = 1
        viewFinder.videoPreviewLayer.session = session
        viewFinder.videoPreviewLayer.videoGravity = .resizeAspectFill
        
        // Store a reference to the view in the ViewModel for later use
        viewModel.owningView = viewFinder
        
        // Always use portrait orientation (90°) for camera preview
        if let connection = viewFinder.videoPreviewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            print("🔒 INITIAL PREVIEW ORIENTATION - Locked to portrait (90°)")
        }
        
        print("DEBUG: FRAME CHECK - Initial frame: \(viewFinder.frame), bounds: \(viewFinder.bounds)")
        
        return viewFinder
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        // Always ensure portrait orientation (90°) for camera preview
        if let connection = uiView.videoPreviewLayer.connection,
           connection.isVideoRotationAngleSupported(90) && 
           connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
            print("🔒 UPDATED PREVIEW ORIENTATION - Locked to portrait (90°)")
        }
        
        // Ensure frame matches parent view bounds
        uiView.videoPreviewLayer.frame = uiView.bounds
        
        // Update aspect ratio enforcement
        uiView.updateAspectRatio()
    }
    
    static func dismantleUIView(_ uiView: VideoPreviewView, coordinator: Coordinator) {
        // Remove the orientation change observer when dismantling the view
        NotificationCenter.default.removeObserver(uiView)
    }
}

// Remove this function as it's no longer needed - we're always locking to portrait
// Helper function to update preview orientation
private func updatePreviewOrientation(_ viewFinder: FixedOrientationCameraPreview.VideoPreviewView) {
    guard let connection = viewFinder.videoPreviewLayer.connection else { return }
    
    // Always lock to portrait orientation (90°)
    let rotationAngle: CGFloat = 90
    
    if connection.isVideoRotationAngleSupported(rotationAngle) {
        connection.videoRotationAngle = rotationAngle
    }
} 