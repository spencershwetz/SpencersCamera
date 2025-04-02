import UIKit
import AVFoundation

class CustomPreviewView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
    
    private let session: AVCaptureSession
    
    init(session: AVCaptureSession) {
        self.session = session
        super.init(frame: .zero)
        
        // Set background color immediately
        backgroundColor = .black
        
        // Faster initialization by deferring setup
        DispatchQueue.main.async { [weak self] in
            self?.setupView()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // Override layerClass to return AVCaptureVideoPreviewLayer
    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }
    
    private func setupView() {
        // Configure preview layer with minimal logging
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        
        // Set orientation
        if let connection = previewLayer.connection {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
        
        // Force layout
        setNeedsLayout()
        layoutIfNeeded()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // Use transaction to avoid animation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // Update frame
        previewLayer.frame = bounds
        
        // Ensure proper orientation
        if let connection = previewLayer.connection {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
        
        CATransaction.commit()
    }
} 