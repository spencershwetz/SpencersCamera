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
                // Update orientation to match device orientation
                updateOrientationForConnection(connection)
                print("📱 ORIENTATION CHANGE - Updating camera preview to match device orientation")
                
                // Apply visual rotation transform to the preview layer
                applyRotationTransform()
                
                print("📏 FRAME AFTER ORIENTATION CHANGE - Frame: \(frame), Bounds: \(bounds)")
            }
        }
        
        @objc private func orientationLockEnforced() {
            if let connection = videoPreviewLayer.connection {
                // Update orientation when orientation lock is enforced
                updateOrientationForConnection(connection)
                
                // Also update visual rotation when orientation is enforced
                applyRotationTransform()
            }
        }
        
        internal func updateOrientationForConnection(_ connection: AVCaptureConnection) {
            // Get current device and interface orientation
            let deviceOrientation = UIDevice.current.orientation
            let interfaceOrientation: UIInterfaceOrientation
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                interfaceOrientation = windowScene.interfaceOrientation
            } else {
                interfaceOrientation = .portrait
            }
            
            // Log the current orientations
            print("🔄 ADAPTING PREVIEW - Physical Device: \(deviceOrientation.rawValue), Interface: \(interfaceOrientation.rawValue)")
            
            // Determine the appropriate rotation angle based on interface orientation
            let rotationAngle = getRotationAngle(for: interfaceOrientation)
            
            // Apply the rotation
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
                print("✅ Applied rotation angle (\(rotationAngle)°) to match device orientation")
            } else {
                print("⚠️ Rotation angle \(rotationAngle)° not supported by connection")
            }
            
            // Ensure the video gravity is set to fill the available space
            // This is important for maintaining proper visual appearance in all orientations
            videoPreviewLayer.videoGravity = .resizeAspectFill
        }
        
        // Apply a visual rotation transform to make the preview look correct in landscape
        internal func applyRotationTransform() {
            // Get device and interface orientation
            let deviceOrientation = UIDevice.current.orientation
            let interfaceOrientation: UIInterfaceOrientation
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                interfaceOrientation = windowScene.interfaceOrientation
            } else {
                interfaceOrientation = .portrait
            }
            
            print("🔄 APPLYING VISUAL TRANSFORM - Device orientation: \(deviceOrientation.rawValue), Interface: \(interfaceOrientation.rawValue)")
            
            // First reset any existing transform
            videoPreviewLayer.transform = CATransform3DIdentity
            
            // Only apply visual rotation in landscape modes
            switch interfaceOrientation {
            case .landscapeLeft:
                // Landscape Left (Home button on left)
                print("🔄 Rotating preview display for landscape left")
                let rotation = CGFloat.pi / 2 // 90 degrees clockwise
                videoPreviewLayer.transform = CATransform3DMakeRotation(rotation, 0, 0, 1)
                
            case .landscapeRight:
                // Landscape Right (Home button on right)
                print("🔄 Rotating preview display for landscape right")
                let rotation = -CGFloat.pi / 2 // 90 degrees counter-clockwise
                videoPreviewLayer.transform = CATransform3DMakeRotation(rotation, 0, 0, 1)
                
            default:
                // No visual transform needed for portrait modes
                print("🔄 No visual rotation needed for portrait orientation")
                break
            }
        }
        
        internal func getRotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
            // ALWAYS return portrait orientation (90°) regardless of device/interface orientation
            // This is needed to prevent the camera preview from rotating when the device rotates
            print("📱 Setting camera orientation to FIXED portrait (90°) regardless of device orientation")
            return 90
            
            // Previously, we used to map interface orientation to rotation angle
            // This was causing the camera preview to rotate when the device rotated
            /*
            switch orientation {
            case .portrait:
                print("📱 Setting camera orientation to portrait (90°)")
                return 90
            case .portraitUpsideDown:
                print("📱 Setting camera orientation to portraitUpsideDown (270°)")
                return 270
            case .landscapeLeft:
                print("📱 Setting camera orientation to landscapeLeft (0°)")
                return 0 // Home button on left
            case .landscapeRight:
                print("📱 Setting camera orientation to landscapeRight (180°)")
                return 180 // Home button on right
            default:
                print("📱 Unknown orientation, defaulting to portrait (90°)")
                return 90
            }
            */
        }
        
        // Override layoutSubviews to adjust layout when view size changes
        override func layoutSubviews() {
            super.layoutSubviews()
            
            // Ensure the video preview layer fills the view
            videoPreviewLayer.frame = bounds
            
            // Ensure the focus view stays centered
            focusView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            
            // Update orientation when layout changes
            if let connection = videoPreviewLayer.connection {
                updateOrientationForConnection(connection)
            }
            
            // Apply rotation transform whenever layout changes
            applyRotationTransform()
            
            // Print frame info for debugging
            let isPortrait = bounds.height > bounds.width
            print("📐 PREVIEW LAYER - Frame updated: \(videoPreviewLayer.frame), bounds: \(bounds), isPortrait: \(isPortrait)")
        }
        
        // Support for orientation changes
        func updateOrientation() {
            if let connection = videoPreviewLayer.connection {
                updateOrientationForConnection(connection)
                
                // Also update visual transform
                applyRotationTransform()
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
        
        // Explicitly configure the layer for portrait orientation
        if let connection = viewFinder.videoPreviewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            print("🔄 INITIAL PREVIEW CONFIGURATION - Explicitly setting to portrait (90°)")
        }
        
        // Apply initial visual transform based on current orientation
        viewFinder.applyRotationTransform()
        
        // Store a reference to the view in the ViewModel for later use
        viewModel.owningView = viewFinder
        
        // Set the initial orientation based on the current interface orientation
        if let connection = viewFinder.videoPreviewLayer.connection {
            viewFinder.updateOrientationForConnection(connection)
            print("🔄 INITIAL PREVIEW ORIENTATION - Set based on device orientation")
        }
        
        print("DEBUG: FRAME CHECK - Initial frame: \(viewFinder.frame), bounds: \(viewFinder.bounds)")
        
        return viewFinder
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        // Ensure frame matches parent view bounds
        uiView.videoPreviewLayer.frame = uiView.bounds
        
        // Update orientation based on device orientation
        uiView.updateOrientation()
        
        // Ensure the rotation angle is correct
        if let connection = uiView.videoPreviewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            // Force portrait orientation
            connection.videoRotationAngle = 90
        }
    }
    
    static func dismantleUIView(_ uiView: VideoPreviewView, coordinator: Coordinator) {
        // Remove the orientation change observer when dismantling the view
        NotificationCenter.default.removeObserver(uiView)
    }
} 