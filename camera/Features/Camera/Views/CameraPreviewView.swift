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
        // ADD: Dedicated queue for session configuration
        private let sessionConfigurationQueue = DispatchQueue(label: "com.camera.sessionConfigQueue")
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
            self.previewLayer = AVCaptureVideoPreviewLayer(session: session) // Init directly with session
            // Log init start
            print("➡️ [\(instanceId)] CustomPreviewView.init - START")
            super.init(frame: .zero) // Start with zero frame, let layout handle it
            print("  ➡️ [\(instanceId)] CustomPreviewView.init - Calling setupView()")
            setupView()
            print("  ➡️ [\(instanceId)] CustomPreviewView.init - Calling setupVolumeButtonHandler()")
            setupVolumeButtonHandler() // Setup volume handler here

            // Observe orientation changes
            print("  ➡️ [\(instanceId)] CustomPreviewView.init - Adding Notification Observers")
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
            print("  ➡️ [\(instanceId)] CustomPreviewView.init - Calling initial handleOrientationChange()")
            handleOrientationChange()
            print("➡️ [\(instanceId)] CustomPreviewView.init - END")
        }

        required init?(coder: NSCoder) {
            print("💥 [\(instanceId)] CustomPreviewView.init(coder:) - FATAL ERROR")
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            print("➡️ [\(instanceId)] CustomPreviewView.deinit - START")
            // Remove observers
            print("  ➡️ [\(instanceId)] CustomPreviewView.deinit - Removing Notification Observers")
            NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("RecordingStateChanged"), object: nil)

            // Detach volume handler
            if #available(iOS 17.2, *) {
                print("  ➡️ [\(instanceId)] CustomPreviewView.deinit - Detaching Volume Button Handler")
                let handler = volumeButtonHandler
                Task { @MainActor [weak self] in // Capture self weakly
                    guard let self else { return }
                    handler?.detachFromView(self)
                }
                volumeButtonHandler = nil // Clear reference
            }
             print("➡️ [\(instanceId)] CustomPreviewView.deinit - END")
        }

        private func setupView() {
            print("  ➡️ [\(instanceId)] setupView - START")
            backgroundColor = .black // Set background color here
            layer.addSublayer(previewLayer)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.cornerRadius = cornerRadius
            previewLayer.masksToBounds = true
            print("    ➡️ [\(instanceId)] setupView - PreviewLayer added and configured.")

            // Tag this view for potential lookup (though direct reference is better)
            tag = 100
            print("    ➡️ [\(instanceId)] setupView - View tagged: \(tag)")

            // Use autoresizing mask for simplicity within the UIViewRepresentable context
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            previewLayer.frame = bounds // Initial frame setup
            print("    ➡️ [\(instanceId)] setupView - AutoresizingMask set, previewLayer frame: \(bounds)")
             print("  ➡️ [\(instanceId)] setupView - END")
        }

        private func setupVolumeButtonHandler() {
             print("  ➡️ [\(instanceId)] setupVolumeButtonHandler - START")
             guard let viewModel else {
                 print("  ⚠️ [\(instanceId)] setupVolumeButtonHandler - ViewModel is nil, skipping setup.")
                 return
             }
             if #available(iOS 17.2, *) {
                 volumeButtonHandler = VolumeButtonHandler(viewModel: viewModel)
                 volumeButtonHandler?.attachToView(self)
                 print("    ✅ [\(instanceId)] Volume button handler initialized and attached")
             } else {
                 print("    ⚠️ [\(instanceId)] Volume button recording requires iOS 17.2 or later")
             }
              print("  ➡️ [\(instanceId)] setupVolumeButtonHandler - END")
         }

        @objc private func handleRecordingStateChange() {
             print("🔄 [\(instanceId)] handleRecordingStateChange - START")
             guard let viewModel else {
                 print("  ⚠️ [\(instanceId)] handleRecordingStateChange - ViewModel is nil, skipping.")
                 return
             }
             let isRecording = viewModel.isRecording
             print("  ℹ️ [\(instanceId)] handleRecordingStateChange - isRecording: \(isRecording)")
             // Animate border on the main layer of this view
             let animation = CABasicAnimation(keyPath: "borderColor")
             animation.fromValue = isRecording ? UIColor.clear.cgColor : UIColor.red.cgColor
             animation.toValue = isRecording ? UIColor.red.cgColor : UIColor.clear.cgColor
             animation.duration = 0.3
             animation.fillMode = .forwards
             animation.isRemovedOnCompletion = false
             layer.borderWidth = isRecording ? 4.0 : 0.0 // Set border width
             layer.cornerRadius = cornerRadius // Ensure corner radius is consistent
             print("  ➡️ [\(instanceId)] handleRecordingStateChange - Adding border animation.")
             layer.add(animation, forKey: "borderColorAnimation")

             if isRecording {
                 layer.borderColor = UIColor.red.cgColor // Ensure final state
                 print("    ➡️ [\(instanceId)] handleRecordingStateChange - Border color set to Red.")
             } else {
                 print("    ➡️ [\(instanceId)] handleRecordingStateChange - Border width set to 0.")
                 // Remove border color explicitly after animation if needed,
                 // but setting width to 0 should suffice.
             }
             print("🔄 [\(instanceId)] handleRecordingStateChange - END")
        }

        @objc private func handleOrientationChange() {
             print("🔄 [\(instanceId)] handleOrientationChange - START")
             // Get current interface orientation (safer than device orientation)
             let newOrientation = window?.windowScene?.interfaceOrientation ?? .portrait
             print("  ℹ️ [\(instanceId)] handleOrientationChange - Detected windowScene orientation: \(newOrientation.description)")
             guard newOrientation.isPortrait || newOrientation.isLandscape else {
                 print("  ⚠️ [\(instanceId)] handleOrientationChange - Ignoring non-landscape/portrait orientation: \(newOrientation.description)")
                 return
             } // Ignore faceup/down

             // Only update if orientation actually changed
             guard newOrientation != currentInterfaceOrientation else {
                 print("  ℹ️ [\(instanceId)] handleOrientationChange - Orientation (\(newOrientation.description)) hasn't changed. Skipping update.")
                 return
             }
             let oldOrientation = currentInterfaceOrientation
             currentInterfaceOrientation = newOrientation

             // CHANGE: Use the new description property for logging
             print("  ➡️ [\(instanceId)] handleOrientationChange - Orientation changed from \(oldOrientation.description) to \(currentInterfaceOrientation.description)")

             // Update preview layer orientation
              print("    ➡️ [\(instanceId)] handleOrientationChange - Updating PreviewLayer connection.")
             updateConnectionOrientation(for: previewLayer.connection)

             // Update data output orientation if it exists
             if let dataOutput = dataOutput {
                 print("    ➡️ [\(instanceId)] handleOrientationChange - Updating DataOutput connection.")
                 updateConnectionOrientation(for: dataOutput.connection(with: .video))
             } else {
                  print("    ℹ️ [\(instanceId)] handleOrientationChange - No DataOutput exists to update.")
             }
              print("🔄 [\(instanceId)] handleOrientationChange - END")
         }

        // Helper to set connection orientation based on currentInterfaceOrientation
         private func updateConnectionOrientation(for connection: AVCaptureConnection?) {
             print("    ➡️ [\(instanceId)] updateConnectionOrientation - START")
             guard let connection else {
                  print("    ⚠️ [\(instanceId)] updateConnectionOrientation - Connection is nil. Skipping.")
                 return
             }

             // CHANGE: Set rotation based on interface orientation
             let rotationAngle: CGFloat
             switch currentInterfaceOrientation {
             case .portrait:
                 rotationAngle = 90
             case .landscapeLeft:
                 rotationAngle = 0 // Corrected
             case .landscapeRight:
                 rotationAngle = 180 // Corrected
             case .portraitUpsideDown:
                 rotationAngle = 270
             default:
                 rotationAngle = 90 // Default to portrait
             }
              print("      ℹ️ [\(instanceId)] updateConnectionOrientation - Target angle: \(rotationAngle) for \(currentInterfaceOrientation.description)")

             if connection.isVideoRotationAngleSupported(rotationAngle) {
                 connection.videoRotationAngle = rotationAngle
                 // Use the new description property for logging
                 print("      ✅ [\(instanceId)] Updated connection (\(connection.description.suffix(10))) angle to: \(rotationAngle)")
             } else {
                 // Use the new description property for logging
                 print("      ⚠️ [\(instanceId)] Rotation angle \(rotationAngle) not supported for connection (\(connection.description.suffix(10)))")
             }
              print("    ➡️ [\(instanceId)] updateConnectionOrientation - END")
         }

        override func layoutSubviews() {
            print("🔄 [\(instanceId)] layoutSubviews - START")
            super.layoutSubviews()
            print("  ℹ️ [\(instanceId)] layoutSubviews - Current bounds: \(bounds)")
            // Ensure preview layer frame matches bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            print("    ➡️ [\(instanceId)] layoutSubviews - Setting previewLayer frame: \(bounds)")
            previewLayer.frame = bounds // Preview layer matches view bounds
            // Update LUT overlay frame if it exists
            if let overlay = previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                 print("    ➡️ [\(instanceId)] layoutSubviews - Updating LUTOverlayLayer frame: \(bounds)")
                overlay.frame = bounds // LUT overlay also matches view bounds
                overlay.cornerRadius = cornerRadius
            } else {
                 print("    ℹ️ [\(instanceId)] layoutSubviews - No LUTOverlayLayer found.")
            }
            CATransaction.commit()
            print("🔄 [\(instanceId)] layoutSubviews - END")
        }

        func updateLUT(_ filter: CIFilter?) {
            print("🔄 [\(instanceId)] updateLUT - START - Received filter: \(filter?.name ?? "nil")")
            // Skip if same filter (reference equality)
            if (filter === currentLUTFilter) {
                 print("  ℹ️ [\(instanceId)] updateLUT - New filter is identical to current. Skipping.")
                return
            }

            let hadFilterBefore = (currentLUTFilter != nil)
            let hasFilterNow = (filter != nil)
             print("  ℹ️ [\(instanceId)] updateLUT - State change: Had Filter? \(hadFilterBefore), Has Filter Now? \(hasFilterNow)")

            // Update our internal filter reference *before* dispatching changes
            currentLUTFilter = filter

            // Update processing based on state change
            if hasFilterNow && !hadFilterBefore {
                 print("    ➡️ [\(instanceId)] updateLUT - Adding new filter. Calling setupDataOutput().")
                // New filter added when none existed
                setupDataOutput() // Dispatch session changes internally
            } else if !hasFilterNow && hadFilterBefore {
                 print("    ➡️ [\(instanceId)] updateLUT - Removing filter. Dispatching overlay removal to main thread.")
                // Filter removed
                // Remove overlay first on main thread
                DispatchQueue.main.async { [weak self] in
                    // Capture instanceId directly as it's a constant
                    let instanceId = self?.instanceId ?? UUID() // Get ID or a fallback
                    guard let self = self else {
                         print("    ⚠️ [\(instanceId)] updateLUT (main) - Self is nil after dispatch. Cannot remove overlay.")
                        return
                    }
                     print("      ➡️ [\(instanceId)] updateLUT (main) - Removing LUT overlay layer.")
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    if let overlay = self.previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                        overlay.removeFromSuperlayer()
                        print("        ✅ [\(instanceId)] updateLUT (main) - LUT overlay layer removed.")
                    } else {
                         print("        ℹ️ [\(instanceId)] updateLUT (main) - No LUT overlay layer found to remove.")
                    }
                    CATransaction.commit()

                    // Then dispatch the removal of the data output
                    print("      ➡️ [\(instanceId)] updateLUT (main) - Calling removeDataOutput().")
                    self.removeDataOutput()
                }
            } else if hasFilterNow && hadFilterBefore {
                 print("    ℹ️ [\(instanceId)] updateLUT - Filter changed from one LUT to another. No setup/removal needed.")
            } // else: !hasFilterNow && !hadFilterBefore - No change (both nil)

            if filter != nil {
                print("  ✅ [\(instanceId)] updateLUT - CustomPreviewView updated with new LUT filter: \(filter?.name ?? "Unknown")")
            } else {
                print("  ✅ [\(instanceId)] updateLUT - CustomPreviewView cleared LUT filter.")
            }
             print("🔄 [\(instanceId)] updateLUT - END")
        }
        
        private func setupDataOutput() {
             // Capture instanceId directly as it's a constant
             let viewInstanceId = self.instanceId // Capture before async
             print("  ➡️ [\(viewInstanceId)] setupDataOutput - START - Dispatching to sessionConfigurationQueue.")
            // Dispatch session changes to the dedicated background queue
            sessionConfigurationQueue.async { [weak self] in
                 let instanceId = viewInstanceId // Use captured ID
                 print("    ➡️ [\(instanceId)] setupDataOutput (config queue) - START")
                guard let self = self else {
                     print("    ⚠️ [\(instanceId)] setupDataOutput (config queue) - Self is nil after dispatch.")
                    return
                 }

                let wasRunning = self.session.isRunning
                if wasRunning {
                    print("      ⏸️ [\(instanceId)] setupDataOutput (config queue) - Stopping session before modification.")
                    self.session.stopRunning()
                }

                 print("      ➡️ [\(instanceId)] setupDataOutput (config queue) - Begin session configuration.")
                self.session.beginConfiguration()

                // Create new video data output
                let output = AVCaptureVideoDataOutput()
                output.setSampleBufferDelegate(self, queue: self.processingQueue) // Use the LUT processing queue
                output.alwaysDiscardsLateVideoFrames = true
                 print("        ➡️ [\(instanceId)] setupDataOutput (config queue) - Created AVCaptureVideoDataOutput.")

                // Set video settings for compatibility with CoreImage
                let settings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                output.videoSettings = settings
                 print("        ➡️ [\(instanceId)] setupDataOutput (config queue) - Set video settings: \(settings)")

                // Remove previous output if exists before adding new one
                if let existingOutput = self.dataOutput {
                     print("        ➡️ [\(instanceId)] setupDataOutput (config queue) - Removing existing data output: \(existingOutput)")
                    self.session.removeOutput(existingOutput)
                    self.dataOutput = nil // Clear immediately after removal starts
                     print("          ✅ [\(instanceId)] setupDataOutput (config queue) - Existing output removed.")
                } else {
                     print("        ℹ️ [\(instanceId)] setupDataOutput (config queue) - No existing data output to remove.")
                }

                var addedSuccessfully = false
                 print("        ➡️ [\(instanceId)] setupDataOutput (config queue) - Attempting to add new output...")
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                    self.dataOutput = output // Assign *after* adding successfully
                    addedSuccessfully = true
                     print("          ✅ [\(instanceId)] setupDataOutput (config queue) - Successfully added new output: \(output)")

                    // Ensure proper orientation using the helper function
                    if let connection = output.connection(with: .video) {
                         print("            ➡️ [\(instanceId)] setupDataOutput (config queue) - Updating connection orientation for new output.")
                        self.updateConnectionOrientation(for: connection)
                    } else {
                         print("            ⚠️ [\(instanceId)] setupDataOutput (config queue) - Could not get connection for new output.")
                    }

                } else {
                    self.dataOutput = nil // Ensure it's nil if adding failed
                     print("          ❌ [\(instanceId)] setupDataOutput (config queue) - ERROR: Could not add video data output.")
                }

                 print("      ➡️ [\(instanceId)] setupDataOutput (config queue) - Commit session configuration.")
                self.session.commitConfiguration()

                 if !addedSuccessfully {
                     self.dataOutput = nil
                     print("        ⚠️ [\(instanceId)] setupDataOutput (config queue) - Re-verified dataOutput is nil after failed add.")
                 }

                if wasRunning {
                    print("      ▶️ [\(instanceId)] setupDataOutput (config queue) - Restarting session after modification.")
                    self.session.startRunning()
                }

                 print("    ➡️ [\(instanceId)] setupDataOutput (config queue) - END")
            }
        }
        
        private func removeDataOutput() {
            // 1. Remove overlay on main thread FIRST (handled by the caller: updateLUT)
            // Capture instanceId directly as it's a constant
            let viewInstanceId = self.instanceId // Capture before async
            print("  ➡️ [\(viewInstanceId)] removeDataOutput - START - Dispatching to sessionConfigurationQueue.")
            // 2. Remove output on config queue
            sessionConfigurationQueue.async { [weak self] in
                 let instanceId = viewInstanceId // Use captured ID
                 print("    ➡️ [\(instanceId)] removeDataOutput (config queue) - START")
                guard let self = self else {
                     print("    ⚠️ [\(instanceId)] removeDataOutput (config queue) - Self is nil after dispatch.")
                    return
                }
                guard let outputToRemove = self.dataOutput else {
                    print("    ℹ️ [\(instanceId)] removeDataOutput (config queue) - No dataOutput exists to remove. Skipping.")
                    return // Exit if no output to remove
                }

                // Ensure reference is cleared *before* potential blocking call
                self.dataOutput = nil
                print("      ➡️ [\(instanceId)] removeDataOutput (config queue) - Internal dataOutput reference cleared.")

                let wasRunning = self.session.isRunning
                if wasRunning {
                    print("      ⏸️ [\(instanceId)] removeDataOutput (config queue) - Stopping session before modification.")
                    self.session.stopRunning()
                }

                print("      ➡️ [\(instanceId)] removeDataOutput (config queue) - Begin session configuration.")
                self.session.beginConfiguration()
                 print("        ➡️ [\(instanceId)] removeDataOutput (config queue) - Removing output: \(outputToRemove)")
                self.session.removeOutput(outputToRemove)
                print("      ➡️ [\(instanceId)] removeDataOutput (config queue) - Commit session configuration.")
                self.session.commitConfiguration()

                if wasRunning {
                    print("      ▶️ [\(instanceId)] removeDataOutput (config queue) - Restarting session after modification.")
                    self.session.startRunning()
                }

                print("    ✅ [\(instanceId)] removeDataOutput (config queue) - Successfully removed video data output.")
                 print("    ➡️ [\(instanceId)] removeDataOutput (config queue) - END")
            }
        }
        
        // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
        
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            // print("🖼️ [\(instanceId)] captureOutput - START") // This can be very noisy, enable if needed
            guard let currentLUTFilter = currentLUTFilter else {
                // print("  ℹ️ [\(instanceId)] captureOutput - No active LUT filter. Skipping frame processing.")
                // If no LUT is active, simply return and do nothing.
                return
            }
            // print("  ➡️ [\(instanceId)] captureOutput - Active LUT: \(currentLUTFilter.name ?? "Unknown")")
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                 print("  ⚠️ [\(instanceId)] captureOutput - Failed to get pixel buffer from sample buffer.")
                return
            }
            // print("  ➡️ [\(instanceId)] captureOutput - Got PixelBuffer.")

            // Create CIImage from the pixel buffer
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            // print("  ➡️ [\(instanceId)] captureOutput - Created CIImage.")

            // Apply LUT filter
            currentLUTFilter.setValue(ciImage, forKey: kCIInputImageKey)
            // print("  ➡️ [\(instanceId)] captureOutput - Applied LUT filter.")

            guard let outputImage = currentLUTFilter.outputImage else {
                 print("  ⚠️ [\(instanceId)] captureOutput - LUT filter produced nil outputImage.")
                 return
            }
             // print("  ➡️ [\(instanceId)] captureOutput - Got output CIImage from filter.")

            // Optimization: Check if context can render directly to a CVPixelBuffer if performance becomes an issue.
            // For now, createCGImage is standard.
            guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
                print("  ⚠️ [\(instanceId)] captureOutput - Failed to create CGImage from LUT output CIImage.")
                return
            }
             // print("  ➡️ [\(instanceId)] captureOutput - Created CGImage. Dispatching to main thread for overlay update.")

            // Create or update overlay on main thread
            DispatchQueue.main.async { [weak self] in
                // Capture instanceId directly as it's a constant
                let instanceId = self?.instanceId ?? UUID() // Get ID or a fallback
                // print("    ➡️ [\(instanceId)] captureOutput (main) - Updating overlay.")
                guard let self = self else {
                     print("    ⚠️ [\(instanceId)] captureOutput (main) - Self is nil after dispatch.")
                    return
                }
                
                CATransaction.begin()
                CATransaction.setDisableActions(true) // Prevent flicker/animations
                
                let currentBounds = self.bounds // Use the view's current bounds
                 // print("      ℹ️ [\(instanceId)] captureOutput (main) - Current view bounds: \(currentBounds)")

                // Update existing overlay or create a new one
                if let overlay = self.previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                     // print("      ➡️ [\(instanceId)] captureOutput (main) - Updating existing overlay contents.")
                    overlay.contents = cgImage
                    // Update frame only if it differs to avoid redundant work
                    if overlay.frame != currentBounds {
                       overlay.frame = currentBounds
                       // print("        ➡️ [\(instanceId)] captureOutput (main) - Updated overlay frame.")
                    }
                     // Ensure corner radius matches (might change if view resizes)
                     if overlay.cornerRadius != self.cornerRadius {
                        overlay.cornerRadius = self.cornerRadius
                        // print("        ➡️ [\(instanceId)] captureOutput (main) - Updated overlay corner radius.")
                     }
                } else {
                     print("      ➡️ [\(instanceId)] captureOutput (main) - Creating new overlay layer.")
                    let overlayLayer = CALayer()
                    overlayLayer.name = "LUTOverlayLayer"
                    overlayLayer.frame = currentBounds // Use current bounds
                    overlayLayer.contentsGravity = .resizeAspectFill // Fill bounds
                    overlayLayer.contents = cgImage
                    overlayLayer.cornerRadius = self.cornerRadius
                    overlayLayer.masksToBounds = true // Clip to rounded corners
                    self.previewLayer.addSublayer(overlayLayer)
                    print("        ✅ [\(instanceId)] captureOutput (main) - Added LUT overlay layer with frame: \(currentBounds)")
                }
                
                CATransaction.commit()
                 // print("    ➡️ [\(instanceId)] captureOutput (main) - Overlay update finished.")
            }
             // print("🖼️ [\(instanceId)] captureOutput - END") // This can be very noisy, enable if needed
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
