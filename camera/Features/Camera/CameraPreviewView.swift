import SwiftUI
import AVFoundation
import CoreImage
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel

    func makeUIView(context: Context) -> RotationLockedContainer {
        // Create a rotation-locked container to hold our preview
        let container = RotationLockedContainer(frame: UIScreen.main.bounds)
        
        // Create and configure the actual camera preview
        let preview = PreviewView(frame: UIScreen.main.bounds)
        preview.backgroundColor = .black
        
        // Set up the AVCaptureVideoPreviewLayer
        preview.previewLayer.session = session
        preview.previewLayer.videoGravity = .resizeAspectFill
        
        // Force portrait orientation for the preview
        if let connection = preview.previewLayer.connection {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
                print("DEBUG: Set previewLayer videoRotationAngle to 90° (locked portrait orientation)")
            }
        }
        
        // Add the preview to our container
        container.addSubview(preview)
        
        // Pin the preview to the container with auto layout
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            preview.leftAnchor.constraint(equalTo: container.leftAnchor),
            preview.rightAnchor.constraint(equalTo: container.rightAnchor)
        ])
        
        return container
    }
    
    func updateUIView(_ uiView: RotationLockedContainer, context: Context) {
        // Re-enforce the fixed frame and rotation settings
        uiView.frame = UIScreen.main.bounds
        
        // Find and check the preview layer connection
        if let preview = uiView.subviews.first as? PreviewView,
           let connection = preview.previewLayer.connection {
            if connection.videoRotationAngle != 90 && connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
                print("DEBUG: Re-enforced previewLayer videoRotationAngle to 90°")
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject {
        let parent: CameraPreviewView
        
        init(parent: CameraPreviewView) {
            self.parent = parent
            super.init()
        }
    }
    
    // MARK: - Custom Views
    
    // A container view that actively resists rotation changes
    class RotationLockedContainer: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            setupView()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupView()
        }
        
        private func setupView() {
            // Basics
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            backgroundColor = .black
            clipsToBounds = true
            
            // Register for orientation changes
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(orientationDidChange),
                name: UIDevice.orientationDidChangeNotification,
                object: nil
            )
            
            // Also observe interface orientation changes
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(interfaceOrientationDidChange),
                name: UIApplication.didChangeStatusBarOrientationNotification,
                object: nil
            )
            
            print("DEBUG: RotationLockedContainer initialized")
        }
        
        @objc private func orientationDidChange() {
            print("DEBUG: Container detected device orientation change")
            enforceBounds()
        }
        
        @objc private func interfaceOrientationDidChange() {
            print("DEBUG: Container detected interface orientation change")
            enforceBounds()
        }
        
        private func enforceBounds() {
            // Always maintain full screen bounds regardless of rotation
            frame = UIScreen.main.bounds
            
            // Re-enforce rotation settings for all subviews
            for case let preview as PreviewView in subviews {
                preview.frame = bounds
                if let connection = preview.previewLayer.connection {
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                }
            }
        }
        
        // Override these methods to prevent rotation from affecting our view
        override func layoutSubviews() {
            super.layoutSubviews()
            enforceBounds()
        }
        
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            enforceBounds()
        }
        
        override func didMoveToWindow() {
            super.didMoveToWindow()
            enforceBounds()
        }
    }
    
    // The actual camera preview view with AVCaptureVideoPreviewLayer as its layer
    class PreviewView: UIView {
        override class var layerClass: AnyClass {
            return AVCaptureVideoPreviewLayer.self
        }
        
        var previewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setupView()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupView()
        }
        
        private func setupView() {
            // Core setup
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            backgroundColor = .black
            
            // Additional settings to prevent the layer from auto-rotating
            layer.needsDisplayOnBoundsChange = true
            clipsToBounds = true
            
            print("DEBUG: PreviewView set up with AVCaptureVideoPreviewLayer")
        }
        
        // Override to make sure our layer stays correctly sized
        override func layoutSublayers(of layer: CALayer) {
            super.layoutSublayers(of: layer)
            previewLayer.frame = layer.bounds
            
            // Re-enforce rotation whenever the layer updates
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}
