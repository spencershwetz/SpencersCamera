// File: camera/Features/Camera/CameraPreviewImplementation.swift

import SwiftUI
import AVFoundation

/// A SwiftUI view that presents a live camera preview using an AVCaptureVideoPreviewLayer.
/// This implementation allows the preview to rotate with device orientation
struct CameraPreview: UIViewRepresentable {
    private let source: PreviewSource

    init(source: PreviewSource) {
        self.source = source
    }

    func makeUIView(context: Context) -> PreviewView {
        // Allow all orientations
        CameraOrientationLock.unlockForRotation()
        let preview = PreviewView()
        source.connect(to: preview)
        return preview
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // No updates required.
    }
    
    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        // Ensure orientation is unlocked when the preview view is dismantled.
        CameraOrientationLock.unlockForRotation()
    }

    /// A UIView whose backing layer is AVCaptureVideoPreviewLayer.
    /// It sets the session and allows for dynamic rotation.
    class PreviewView: UIView, PreviewTarget {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }
        
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
        
        init() {
            super.init(frame: .zero)
            backgroundColor = .black
            
            // Register for orientation change notifications
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(orientationChanged),
                name: UIDevice.orientationDidChangeNotification,
                object: nil
            )
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        @objc private func orientationChanged() {
            updatePreviewOrientation()
        }
        
        private func updatePreviewOrientation() {
            if let connection = previewLayer.connection {
                // Get current device orientation for logging purposes
                let deviceOrientation = UIDevice.current.orientation
                
                // Get interface orientation for consistent handling
                let interfaceOrientation: UIInterfaceOrientation
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    interfaceOrientation = windowScene.interfaceOrientation
                } else {
                    interfaceOrientation = .portrait
                }
                
                // Use interface orientation for more consistent behavior
                let rotationAngle: CGFloat
                switch interfaceOrientation {
                case .portrait:
                    rotationAngle = 90
                case .portraitUpsideDown:
                    rotationAngle = 270
                case .landscapeLeft: // Home button on left
                    rotationAngle = 0  // Fixed: Left = 0°
                case .landscapeRight: // Home button on right
                    rotationAngle = 180 // Fixed: Right = 180°
                default:
                    rotationAngle = 90
                }
                
                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                    print("DEBUG: Preview orientation updated to \(rotationAngle)° for interface orientation \(interfaceOrientation.rawValue), device: \(deviceOrientation.rawValue)")
                }
            }
        }
        
        func setSession(_ session: AVCaptureSession) {
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            
            // Set initial orientation
            updatePreviewOrientation()
        }
    }
}

/// A protocol to allow connecting an AVCaptureSession to a preview view.
@preconcurrency
protocol PreviewSource: Sendable {
    func connect(to target: PreviewTarget)
}

/// A protocol that defines a preview target which can accept an AVCaptureSession.
protocol PreviewTarget {
    func setSession(_ session: AVCaptureSession)
}

/// The default implementation for connecting a session.
struct DefaultPreviewSource: PreviewSource {
    private let session: AVCaptureSession
    
    init(session: AVCaptureSession) {
        self.session = session
    }
    
    func connect(to target: PreviewTarget) {
        target.setSession(session)
    }
    
    func makeUIView() -> UIView {
        let view = UIView()
        let previewLayer = AVCaptureVideoPreviewLayer()
        
        // Configure preview layer
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        
        // Set initial orientation based on interface orientation
        if let connection = previewLayer.connection {
            // Get interface orientation for consistent handling
            let interfaceOrientation: UIInterfaceOrientation
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                interfaceOrientation = windowScene.interfaceOrientation
            } else {
                interfaceOrientation = .portrait
            }
            
            // Use interface orientation for consistent behavior
            let rotationAngle: CGFloat
            switch interfaceOrientation {
            case .portrait:
                rotationAngle = 90
            case .portraitUpsideDown:
                rotationAngle = 270
            case .landscapeLeft: // Home button on left
                rotationAngle = 0  // Fixed: Left = 0°
            case .landscapeRight: // Home button on right
                rotationAngle = 180 // Fixed: Right = 180°
            default:
                rotationAngle = 90 // Default to portrait
            }
            
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
                print("DEBUG: DefaultPreviewSource set rotation to \(rotationAngle)° for interface \(interfaceOrientation.rawValue)")
            }
        }
        
        // Add preview layer to view
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        
        return view
    }
    
    func updateUIView(_ uiView: UIView) {
        guard let previewLayer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer else {
            return
        }
        
        // Update orientation based on interface orientation
        if let connection = previewLayer.connection {
            // Get interface orientation for consistent handling
            let interfaceOrientation: UIInterfaceOrientation
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                interfaceOrientation = windowScene.interfaceOrientation
            } else {
                interfaceOrientation = .portrait
            }
            
            // Use interface orientation for consistent behavior
            let rotationAngle: CGFloat
            switch interfaceOrientation {
            case .portrait:
                rotationAngle = 90
            case .portraitUpsideDown:
                rotationAngle = 270
            case .landscapeLeft: // Home button on left
                rotationAngle = 0  // Fixed: Left = 0°
            case .landscapeRight: // Home button on right
                rotationAngle = 180 // Fixed: Right = 180°
            default:
                rotationAngle = 90 // Default to portrait
            }
            
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
        }
        
        // Update frame to match view
        previewLayer.frame = uiView.bounds
    }
}
