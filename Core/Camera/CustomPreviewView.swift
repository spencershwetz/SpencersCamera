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
            guard let self = self else { return }
            
            self.setupView()
            self.configurePreviewLayerColorSpace()
            
            // Schedule another check after a delay to catch any race conditions
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                print("DEBUG: Performing delayed base Apple Log configuration check")
                self?.configurePreviewLayerColorSpace()
            }
            
            // Add observer for color space changes
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleColorSpaceChange),
                name: NSNotification.Name("ColorSpaceChanged"),
                object: nil
            )
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleColorSpaceChange(_ notification: Notification) {
        // When color space changes, update the preview layer configuration
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Check if we have specific color space info
            if let colorSpaceInfo = notification.userInfo?["colorSpace"] as? String {
                print("DEBUG: Base preview received color space change: \(colorSpaceInfo)")
                
                if colorSpaceInfo == "appleLog" {
                    // Force a more aggressive reset for Apple Log
                    self.resetPreviewLayerForAppleLog()
                } else {
                    // Regular configuration for sRGB
                    self.configurePreviewLayerColorSpace()
                }
            } else {
                // Fallback to standard configuration
                self.configurePreviewLayerColorSpace()
            }
        }
    }
    
    private func resetPreviewLayerForAppleLog() {
        print("DEBUG: Base view performing aggressive reset for Apple Log display")
        
        // Remove and re-add the preview layer
        previewLayer.removeFromSuperlayer()
        layer.insertSublayer(previewLayer, at: 0)
        
        // Reset the session connection
        let originalSession = previewLayer.session
        previewLayer.session = nil
        previewLayer.session = originalSession
        
        // Force a layout update
        setNeedsLayout()
        layoutIfNeeded()
        
        print("DEBUG: Base view completed aggressive reset for Apple Log display")
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
    
    private func configurePreviewLayerColorSpace() {
        // Ensure the preview layer can properly display Apple Log content
        let deviceInput = session.inputs.first(where: { $0 is AVCaptureDeviceInput }) as? AVCaptureDeviceInput
        guard let device = deviceInput?.device else {
            print("DEBUG: No camera device found for preview layer color space configuration")
            return
        }
        
        // Configure based on device color space
        if device.activeColorSpace == .appleLog {
            print("DEBUG: Configuring base preview layer for Apple Log color space")
            
            // For Apple Log, reset the preview layer to ensure proper rendering
            previewLayer.removeFromSuperlayer()
            layer.insertSublayer(previewLayer, at: 0)
            
            // Toggle session to force a refresh of the preview
            let originalSession = previewLayer.session
            previewLayer.session = nil
            previewLayer.session = originalSession
            
            print("DEBUG: Reset base preview layer for Apple Log display")
        }
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