import SwiftUI
import AVFoundation
import CoreImage
import AVKit

// CHANGE: Add extension for UIInterfaceOrientation description (can be moved later)
extension UIInterfaceOrientation {
    var description: String {
        switch self {
        case .unknown: return "unknown"
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        @unknown default: return "unknown_\(rawValue)"
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel
    private let viewInstanceId = UUID() // Add for logging

    func makeUIView(context: Context) -> CustomPreviewView {
        print("DEBUG: [\(viewInstanceId)] Creating CustomPreviewView")
        let preview = CustomPreviewView(
            session: session,
            lutManager: lutManager,
            viewModel: viewModel
        )
        // Store reference directly to the preview view
        viewModel.owningView = preview
        print("DEBUG: [\(viewInstanceId)] Stored reference to CustomPreviewView in viewModel")
        return preview
    }

    func updateUIView(_ uiView: CustomPreviewView, context: Context) {
        // Update LUT if needed
        // Check reference equality first to avoid unnecessary updates/warnings
        if uiView.currentLUTFilter !== lutManager.currentLUTFilter {
            print("DEBUG: [\(viewInstanceId)] updateUIView - Updating LUT filter.")
            uiView.updateLUT(lutManager.currentLUTFilter)
        } else {
            // print("DEBUG: [\(viewInstanceId)] updateUIView - LUT filter unchanged.")
        }

        // Update the reference in viewModel if it somehow changed (less likely now)
        if viewModel.owningView !== uiView {
            viewModel.owningView = uiView
            print("DEBUG: [\(viewInstanceId)] updateUIView - Updated owningView reference.")
        }
    }

    class CustomPreviewView: UIView, AVCaptureVideoDataOutputSampleBufferDelegate {
        let previewLayer: AVCaptureVideoPreviewLayer
        private var dataOutput: AVCaptureVideoDataOutput?
        let session: AVCaptureSession
        // CHANGE: Make lutManager private if only updated via updateLUT
        private var lutManager: LUTManager
        // CHANGE: Make viewModel weak to prevent potential retain cycles
        weak var viewModel: CameraViewModel?
        private var ciContext = CIContext(options: [.useSoftwareRenderer: false])
        // CHANGE: Make processingQueue serial for safety
        private let processingQueue = DispatchQueue(label: "com.camera.lutprocessing", qos: .userInitiated)
        // CHANGE: Make currentLUTFilter private
        private(set) var currentLUTFilter: CIFilter? // Keep track internally
        private let cornerRadius: CGFloat = 20.0
        private let instanceId = UUID() // Add for logging
        private var volumeButtonHandler: VolumeButtonHandler? // Move handler here

        // Keep track of the current interface orientation
        private var currentInterfaceOrientation: UIInterfaceOrientation = .portrait

        init(session: AVCaptureSession, lutManager: LUTManager, viewModel: CameraViewModel) {
            self.session = session
            self.lutManager = lutManager
            self.viewModel = viewModel
            
            // Initialize preview layer with session
            self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
            
            // Initialize with zero frame first
            super.init(frame: .zero)
            
            print("DEBUG: [\(instanceId)] CustomPreviewView.init")
            
            // Configure preview layer after init
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = UIScreen.main.bounds
            previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
            previewLayer.connection?.isVideoMirrored = false
            
            // Set up the view
            setupView()
            setupVolumeButtonHandler()

            // Observe orientation changes
            NotificationCenter.default.addObserver(self,
                                                 selector: #selector(handleOrientationChange),
                                                 name: UIDevice.orientationDidChangeNotification,
                                                 object: nil)
            // Observe recording state changes
            NotificationCenter.default.addObserver(self,
                                                 selector: #selector(handleRecordingStateChange),
                                                 name: NSNotification.Name("RecordingStateChanged"),
                                                 object: nil)

            // Set initial orientation
            handleOrientationChange()
            
            // Force initial layout
            setNeedsLayout()
            layoutIfNeeded()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            print("DEBUG: [\(instanceId)] CustomPreviewView.deinit")
            // Remove observers
            NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("RecordingStateChanged"), object: nil)

            // Detach volume handler
            if #available(iOS 17.2, *) {
                let handler = volumeButtonHandler
                Task { @MainActor [weak self] in // Capture self weakly
                    guard let self else { return }
                    handler?.detachFromView(self)
                }
                volumeButtonHandler = nil // Clear reference
            }
        }

        private func setupView() {
            print("DEBUG: [\(instanceId)] setupView")
            
            // Set background color
            backgroundColor = .black
            
            // Remove any existing layers
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            
            // Configure preview layer
            previewLayer.frame = bounds
            previewLayer.masksToBounds = true
            previewLayer.cornerRadius = cornerRadius
            previewLayer.isHidden = false
            
            // Add preview layer as the first sublayer
            layer.insertSublayer(previewLayer, at: 0)
            
            // Tag this view for potential lookup
            tag = 100
            
            // Ensure proper orientation
            if let connection = previewLayer.connection {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                    print("DEBUG: Set initial preview layer rotation to 90°")
                }
            }
            
            // Set up video data output if needed
            if currentLUTFilter != nil {
                setupDataOutput()
            }
            
            // Update frame to screen bounds
            frame = UIScreen.main.bounds
            
            print("DEBUG: Preview layer frame after setup: \(previewLayer.frame)")
            print("DEBUG: View frame after setup: \(frame)")
        }

        private func setupVolumeButtonHandler() {
             guard let viewModel else { return } // Ensure viewModel exists
             if #available(iOS 17.2, *) {
                 volumeButtonHandler = VolumeButtonHandler(viewModel: viewModel)
                 volumeButtonHandler?.attachToView(self)
                 print("✅ [\(instanceId)] Volume button handler initialized and attached")
             } else {
                 print("⚠️ [\(instanceId)] Volume button recording requires iOS 17.2 or later")
             }
         }

        @objc private func handleRecordingStateChange() {
             // Update border based on viewModel state
             guard let viewModel else { return }
             let isRecording = viewModel.isRecording
             // Animate border on the main layer of this view
             let animation = CABasicAnimation(keyPath: "borderColor")
             animation.fromValue = isRecording ? UIColor.clear.cgColor : UIColor.red.cgColor
             animation.toValue = isRecording ? UIColor.red.cgColor : UIColor.clear.cgColor
             animation.duration = 0.3
             animation.fillMode = .forwards
             animation.isRemovedOnCompletion = false
             layer.borderWidth = isRecording ? 4.0 : 0.0 // Set border width
             layer.cornerRadius = cornerRadius // Ensure corner radius is consistent
             layer.add(animation, forKey: "borderColorAnimation")

             if isRecording {
                 layer.borderColor = UIColor.red.cgColor // Ensure final state
             } else {
                 // Remove border color explicitly after animation if needed,
                 // but setting width to 0 should suffice.
             }
        }

        @objc private func handleOrientationChange() {
             // Get current interface orientation (safer than device orientation)
             let newOrientation = window?.windowScene?.interfaceOrientation ?? .portrait
             guard newOrientation.isPortrait || newOrientation.isLandscape else { return } // Ignore faceup/down

             // Only update if orientation actually changed
             guard newOrientation != currentInterfaceOrientation else { return }
             currentInterfaceOrientation = newOrientation

             // CHANGE: Use the new description property for logging
             print("DEBUG: [\(instanceId)] handleOrientationChange - New Interface Orientation: \(currentInterfaceOrientation.description)")

             // Update preview layer orientation
             updateConnectionOrientation(for: previewLayer.connection)

             // Update data output orientation if it exists
             if let dataOutput = dataOutput {
                 updateConnectionOrientation(for: dataOutput.connection(with: .video))
             }
         }

        // Helper to set connection orientation based on currentInterfaceOrientation
         private func updateConnectionOrientation(for connection: AVCaptureConnection?) {
             guard let connection else { return }

             // CHANGE: Set rotation based on interface orientation
             let rotationAngle: CGFloat
             switch currentInterfaceOrientation {
             case .portrait:
                 rotationAngle = 90
             case .landscapeLeft:
                 rotationAngle = 180 // Corrected from previous thought, was landscapeRight
             case .landscapeRight:
                 rotationAngle = 0   // Corrected from previous thought, was landscapeLeft
             case .portraitUpsideDown:
                 rotationAngle = 270
             default:
                 rotationAngle = 90 // Default to portrait
             }

             if connection.isVideoRotationAngleSupported(rotationAngle) {
                 connection.videoRotationAngle = rotationAngle
                 // Use the new description property for logging
                 print("DEBUG: [\(instanceId)] Updated connection (\(connection.description.suffix(10))) angle to: \(rotationAngle) for \(currentInterfaceOrientation.description)")
             } else {
                 // Use the new description property for logging
                 print("WARN: [\(instanceId)] Rotation angle \(rotationAngle) not supported for connection (\(connection.description.suffix(10))) for \(currentInterfaceOrientation.description)")
             }
         }

        override func layoutSubviews() {
            super.layoutSubviews()
            
            print("DEBUG: layoutSubviews called - bounds: \(bounds)")
            
            // Update layer frames
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            
            // Update preview layer frame
            previewLayer.frame = bounds
            previewLayer.isHidden = false
            
            // Update LUT overlay if it exists
            if let overlay = previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                overlay.frame = bounds
                overlay.cornerRadius = cornerRadius
            }
            
            // Ensure proper orientation
            if let connection = previewLayer.connection {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
            
            CATransaction.commit()
            
            print("DEBUG: Preview layer frame after layout: \(previewLayer.frame)")
            print("DEBUG: View frame after layout: \(frame)")
        }

        func updateLUT(_ filter: CIFilter?) {
            // Skip if same filter (reference equality)
            if (filter === currentLUTFilter) {
                return
            }
            
            // If filter state changed (nil vs non-nil), update processing
            if (filter != nil) != (currentLUTFilter != nil) {
                if filter != nil {
                    // New filter added when none existed
                    setupDataOutput()
                    
                    // Ensure proper orientation immediately when adding a filter
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        
                        if let connection = self.previewLayer.connection,
                           connection.isVideoRotationAngleSupported(90) {
                            // Force orientation update when LUT is applied
                            connection.videoRotationAngle = 90
                        }
                    }
                } else {
                    // Filter removed - first clean up any existing overlay
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        
                        // Remove any existing LUT overlay layer before removing the data output
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        
                        if let overlay = self.previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                            overlay.removeFromSuperlayer()
                            print("DEBUG: Removed LUT overlay layer during filter update")
                        }
                        
                        CATransaction.commit()
                        
                        // Now remove the data output on the session queue to prevent freezing
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.removeDataOutput()
                        }
                    }
                }
            }
            
            // Update our local reference only - don't modify published properties
            currentLUTFilter = filter
            
            // DON'T update viewModel.lutManager here - this is called during view updates
            // and would trigger the SwiftUI warning
            
            if filter != nil {
                print("DEBUG: CustomPreviewView updated with LUT filter")
            } else {
                print("DEBUG: CustomPreviewView cleared LUT filter")
            }
        }
        
        private func setupDataOutput() {
            // Remove any existing outputs
            if let existingOutput = dataOutput {
                session.removeOutput(existingOutput)
            }
            
            session.beginConfiguration()
            
            // Create new video data output
            let output = AVCaptureVideoDataOutput()
            output.setSampleBufferDelegate(self, queue: processingQueue)
            output.alwaysDiscardsLateVideoFrames = true
            
            // Set video settings for compatibility with CoreImage
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.videoSettings = settings
            
            if session.canAddOutput(output) {
                session.addOutput(output)
                dataOutput = output
                
                // Ensure proper orientation - force portrait
                if let connection = output.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                }
                
                print("DEBUG: Added video data output for LUT processing")
            }
            
            session.commitConfiguration()
        }
        
        private func removeDataOutput() {
            if let output = dataOutput {
                session.beginConfiguration()
                session.removeOutput(output)
                session.commitConfiguration()
                dataOutput = nil
                
                // Clear any existing LUT overlay to prevent freezing
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    
                    // Remove the LUT overlay layer if it exists
                    if let overlay = self.previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                        overlay.removeFromSuperlayer()
                        print("DEBUG: Removed LUT overlay layer")
                    }
                    
                    CATransaction.commit()
                }
                
                print("DEBUG: Removed video data output for LUT processing")
            }
        }
        
        // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
        
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let currentLUTFilter = currentLUTFilter,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            
            // Create CIImage from the pixel buffer
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            
            // Apply LUT filter
            currentLUTFilter.setValue(ciImage, forKey: kCIInputImageKey)
            
            guard let outputImage = currentLUTFilter.outputImage,
                  let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
                return
            }
            
            // Create or update overlay on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                
                // Get the screen bounds
                let screenBounds = UIScreen.main.bounds
                
                // Update existing overlay or create a new one
                if let overlay = self.previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                    overlay.contents = cgImage
                    overlay.frame = screenBounds
                    overlay.cornerRadius = self.cornerRadius
                } else {
                    let overlayLayer = CALayer()
                    overlayLayer.name = "LUTOverlayLayer"
                    overlayLayer.frame = screenBounds
                    overlayLayer.contentsGravity = .resizeAspectFill
                    overlayLayer.contents = cgImage
                    overlayLayer.cornerRadius = self.cornerRadius
                    overlayLayer.masksToBounds = true
                    self.previewLayer.addSublayer(overlayLayer)
                    
                    // Ensure the orientation is correct when overlay is first added
                    if let connection = self.previewLayer.connection,
                       connection.isVideoRotationAngleSupported(90) {
                        // Force orientation update to the preview layer right after adding overlay
                        connection.videoRotationAngle = 90
                    }
                    
                    print("DEBUG: Added LUT overlay layer with frame: \(screenBounds)")
                }
                
                CATransaction.commit()
            }
        }
        
        // Completely prevent any transform-based animations
        override func action(for layer: CALayer, forKey event: String) -> CAAction? {
            if event == "transform" || event == "position" || event == "bounds" {
                return NSNull()
            }
            return super.action(for: layer, forKey: event)
        }
    }
}
