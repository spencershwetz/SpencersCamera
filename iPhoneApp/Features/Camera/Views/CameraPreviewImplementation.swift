// File: camera/Features/Camera/CameraPreviewImplementation.swift

import SwiftUI
import AVFoundation
import os.log

/// A SwiftUI view that presents a live camera preview using an AVCaptureVideoPreviewLayer.
/// This implementation locks the preview to a fixed portrait orientation
/// so that the preview does not rotate even if the device rotates.
struct CameraPreview: UIViewRepresentable {
    private let source: PreviewSource

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraPreviewImpl")

    init(source: PreviewSource) {
        self.source = source
    }

    func makeUIView(context: Context) -> PreviewView {
        let preview = PreviewView()
        source.connect(to: preview)
        return preview
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // No updates required.
    }
    
    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        // Maintain portrait orientation when view is dismantled
    }

    /// A UIView whose backing layer is AVCaptureVideoPreviewLayer.
    /// It sets the session and forces a fixed rotation.
    class PreviewView: UIView, PreviewTarget {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }
        
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
        
        private let viewLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraPreviewImpl.PreviewView")
        
        init() {
            super.init(frame: .zero)
            backgroundColor = .black
            // Do not register for orientation notifications to keep a fixed preview.
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func setSession(_ session: AVCaptureSession) {
            viewLogger.info("Setting session on PreviewView.")
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            
            if let connection = previewLayer.connection {
                // Force a fixed rotation to portrait (90 degrees)
                if connection.isVideoRotationAngleSupported(90) {
                    let currentAngle = connection.videoRotationAngle
                    if currentAngle != 90 {
                        connection.videoRotationAngle = 90
                        viewLogger.info("Set previewLayer connection videoRotationAngle from \(currentAngle)° to 90° (portrait fixed)")
                    } else {
                        viewLogger.debug("PreviewLayer connection videoRotationAngle already 90°.")
                    }
                } else {
                    viewLogger.warning("PreviewLayer connection does not support videoRotationAngle 90°.")
                }
                viewLogger.debug("Current previewLayer connection videoRotationAngle: \(connection.videoRotationAngle)°")
            } else {
                viewLogger.warning("No connection available on previewLayer to set orientation.")
            }
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
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraPreviewImpl.DefaultSource")
    
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
        
        // Force portrait orientation
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            let currentAngle = connection.videoRotationAngle
            if currentAngle != 90 {
                connection.videoRotationAngle = 90
                logger.info("DefaultPreviewSource set rotation from \(currentAngle)° to 90° in makeUIView")
            } else {
                logger.debug("DefaultPreviewSource rotation already 90° in makeUIView.")
            }
        } else {
            logger.warning("DefaultPreviewSource could not set rotation to 90° in makeUIView (supported: \(previewLayer.connection?.isVideoRotationAngleSupported(90) ?? false))")
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
        
        // Force portrait orientation
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            let currentAngle = connection.videoRotationAngle
            if currentAngle != 90 {
                connection.videoRotationAngle = 90
                logger.info("DefaultPreviewSource set rotation from \(currentAngle)° to 90° in updateUIView")
            } else {
                logger.debug("DefaultPreviewSource rotation already 90° in updateUIView.")
            }
        } else {
            logger.warning("DefaultPreviewSource could not set rotation to 90° in updateUIView (supported: \(previewLayer.connection?.isVideoRotationAngleSupported(90) ?? false))")
        }
        
        // Update frame to match view
        previewLayer.frame = uiView.bounds
    }
}
