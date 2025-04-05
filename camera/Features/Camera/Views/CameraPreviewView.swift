import SwiftUI
import AVFoundation
import CoreImage
import AVKit
import Combine
import os.log

// Define delegate protocol outside the main struct
protocol CustomPreviewViewDelegate: AnyObject {
    func customPreviewViewDidAddVideoOutput(_ previewView: CameraPreviewView.CustomPreviewView)
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel
    
    // Logger for CameraPreviewView
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraPreviewView")
    
    func makeUIView(context: Context) -> RotationLockedContainer {
        print("DEBUG: Creating CameraPreviewView")
        
        let customPreview = CustomPreviewView(frame: .zero, // Use zero initially, frame set by container
                                              session: session,
                                              lutManager: lutManager,
                                              viewModel: viewModel)
        
        // Set the delegate AFTER creating the view
        customPreview.delegate = viewModel
        
        // Create container with explicit bounds
        let screen = UIScreen.main.bounds
        let container = RotationLockedContainer(contentView: customPreview)
        
        // Store reference to this container in the view model for LUT processing
        viewModel.owningView = container
        
        // Force layout
        container.setNeedsLayout()
        container.layoutIfNeeded()
        
        return container
    }
    
    func updateUIView(_ uiView: RotationLockedContainer, context: Context) {
        print("DEBUG: updateUIView - Container frame: \(uiView.frame)")
        if let preview = uiView.viewWithTag(100) as? CustomPreviewView {
            print("DEBUG: updateUIView - Preview frame: \(preview.frame)")
            // Use the new updateState method
            preview.updateState(newTimestamp: viewModel.lastLensSwitchTimestamp, newFilter: lutManager.currentLUTFilter)
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
        private let contentView: UIView
        private var borderLayer: CALayer?
        private let cornerRadius: CGFloat = 20.0
        private let borderWidth: CGFloat = 4.0
        private var volumeButtonHandler: VolumeButtonHandler?
        
        init(contentView: UIView) {
            self.contentView = contentView
            super.init(frame: .zero)
            setupView()
            setupBorderLayer()
            setupVolumeButtonHandler()
            
            // Observe recording state changes
            NotificationCenter.default.addObserver(self,
                                                 selector: #selector(handleRecordingStateChange),
                                                 name: NSNotification.Name("RecordingStateChanged"),
                                                 object: nil)
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setupView() {
            // Set background to black
            backgroundColor = .black
            
            // Add content view to fill the container but with space only for border
            addSubview(contentView)
            contentView.translatesAutoresizingMaskIntoConstraints = false
            
            // Create constraints with slightly lower priority
            let topConstraint = contentView.topAnchor.constraint(equalTo: topAnchor, constant: borderWidth)
            let bottomConstraint = contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -borderWidth)
            let leadingConstraint = contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: borderWidth)
            let trailingConstraint = contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -borderWidth)
            
            // Set priority to just below required
            topConstraint.priority = .required - 1
            bottomConstraint.priority = .required - 1
            leadingConstraint.priority = .required - 1
            trailingConstraint.priority = .required - 1
            
            // Activate the constraints
            NSLayoutConstraint.activate([
                topConstraint,
                bottomConstraint,
                leadingConstraint,
                trailingConstraint
            ])
            
            // Disable safe area insets
            contentView.insetsLayoutMarginsFromSafeArea = false
            
            // Set black background for all parent views
            setBlackBackgroundForParentViews()
        }
        
        private func setupBorderLayer() {
            let border = CALayer()
            border.borderWidth = borderWidth
            border.borderColor = UIColor.clear.cgColor
            border.cornerRadius = cornerRadius  // Use the same corner radius as the preview
            layer.addSublayer(border)
            borderLayer = border
        }
        
        private func setupVolumeButtonHandler() {
            if #available(iOS 17.2, *) {
                if let previewView = contentView as? CustomPreviewView {
                    volumeButtonHandler = VolumeButtonHandler(viewModel: previewView.viewModel)
                    volumeButtonHandler?.attachToView(self)
                    print("✅ Volume button handler initialized and attached")
                }
            } else {
                print("⚠️ Volume button recording requires iOS 17.2 or later")
            }
        }
        
        deinit {
            if #available(iOS 17.2, *) {
                // Store a weak reference to volumeButtonHandler before deinit
                let handler = volumeButtonHandler
                let view = self
                Task { @MainActor in
                    handler?.detachFromView(view)
                }
                // Clear the reference
                volumeButtonHandler = nil
            }
        }
        
        @objc private func handleRecordingStateChange() {
            if let viewModel = (contentView as? CustomPreviewView)?.viewModel {
                if viewModel.isRecording {
                    animateBorderIn()
                } else {
                    animateBorderOut()
                }
            }
        }
        
        private func animateBorderIn() {
            let animation = CABasicAnimation(keyPath: "borderColor")
            animation.fromValue = UIColor.clear.cgColor
            animation.toValue = UIColor.red.cgColor
            animation.duration = 0.3
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            borderLayer?.add(animation, forKey: "borderColorAnimation")
        }
        
        private func animateBorderOut() {
            let animation = CABasicAnimation(keyPath: "borderColor")
            animation.fromValue = UIColor.red.cgColor
            animation.toValue = UIColor.clear.cgColor
            animation.duration = 0.3
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            borderLayer?.add(animation, forKey: "borderColorAnimation")
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            
            // Update border frame to match view bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            borderLayer?.frame = bounds
            CATransaction.commit()
            
            // Keep background color black during layout changes
            backgroundColor = .black
            
            // Check for changes in safe area insets
            if safeAreaInsets != .zero {
                // Force content to fill entire view with just border width
                // contentView.frame = bounds.inset(by: UIEdgeInsets(top: borderWidth,
                //                                                 left: borderWidth,
                //                                                 bottom: borderWidth,
                //                                                 right: borderWidth))
            }
            
            // Set black background for parent views
            setBlackBackgroundForParentViews()
        }
        
        private func setBlackBackgroundForParentViews() {
            // Recursively set black background color on all parent views
            var currentView: UIView? = self
            while let view = currentView {
                view.backgroundColor = .black
                
                // Also set any CALayer backgrounds to black
                view.layer.backgroundColor = UIColor.black.cgColor
                
                currentView = view.superview
            }
            
            print("DEBUG: RotationLockedContainer set black background for all parent views")
        }
        
        // Make safe area insets zero to prevent any white bars
        override var safeAreaInsets: UIEdgeInsets {
            return .zero
        }
        
        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            // Force black background when safe area changes
            setBlackBackgroundForParentViews()
        }
    }
    
    // Custom preview view that handles LUT processing
    class CustomPreviewView: UIView, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let previewLayer: AVCaptureVideoPreviewLayer
        private var dataOutput: AVCaptureVideoDataOutput?
        private let session: AVCaptureSession
        private var lutManager: LUTManager
        var viewModel: CameraViewModel
        weak var delegate: CustomPreviewViewDelegate? // Add delegate property
        private let customPreviewLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CustomPreviewView") // Logger for this class
        private var ciContext = CIContext(options: [.useSoftwareRenderer: false])
        private let processingQueue = DispatchQueue(label: "com.camera.lutprocessing", qos: .userInitiated)
        private var currentLUTFilter: CIFilter?
        private let cornerRadius: CGFloat = 20.0
        private var lastProcessedLensSwitchTimestamp: Date?
        private var currentRotationAngle: CGFloat = 90 // Store current angle (default portrait)
        private var orientationObserver: NSObjectProtocol? // Add observer property
        
        // Logger for the deprecated UIView
        private let uiViewLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraPreviewUIView")
        
        init(frame: CGRect, session: AVCaptureSession, lutManager: LUTManager, viewModel: CameraViewModel) {
            self.session = session
            self.lutManager = lutManager
            self.viewModel = viewModel
            self.previewLayer = AVCaptureVideoPreviewLayer()
            super.init(frame: frame)
            setupView()
            setupPreviewLayer()
            setupVideoDataOutput()
            setupOrientationObserver() // Add this call
            
            // Set initial orientation based on current state
            updatePreviewOrientation()
            uiViewLogger.info("Initial orientation set in init.")
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        deinit {
            // Remove observer
            if let observer = orientationObserver {
                NotificationCenter.default.removeObserver(observer)
                uiViewLogger.info("Removed orientation observer.")
            }
        }
        
        private func setupView() {
            // Set tag for lookup in updateUIView
            tag = 100
            
            // Apply corner radius
            layer.cornerRadius = cornerRadius
            layer.masksToBounds = true
            
            // Set background color to black
            backgroundColor = .black
            
            // Initial orientation will be set in didMoveToWindow or via observer
        }
        
        private func setupPreviewLayer() {
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(previewLayer)
            previewLayer.cornerRadius = cornerRadius // Apply initial corner radius
            previewLayer.masksToBounds = true
            uiViewLogger.info("Preview layer setup complete.")
            
            // REMOVED: Orientation should be handled by updatePreviewOrientation
            // updatePreviewOrientation() // Call initially? Better in didMoveToWindow
        }
        
        private func setupVideoDataOutput() {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            output.setSampleBufferDelegate(self, queue: processingQueue)
            
            guard session.canAddOutput(output) else {
                customPreviewLogger.error("Failed to add video data output for LUT processing.") // Use customPreviewLogger
                return
            }
            session.addOutput(output)
            self.dataOutput = output
            customPreviewLogger.info("Added video data output for LUT processing.") // Use customPreviewLogger
            print("DEBUG: Added video data output for LUT processing")
            
            // Call the delegate method after adding the output
            delegate?.customPreviewViewDidAddVideoOutput(self)
            customPreviewLogger.debug("Called customPreviewViewDidAddVideoOutput delegate method.") // Use customPreviewLogger
        }
        
        private func setupOrientationObserver() {
            orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main) { [weak self] _ in
                    guard let self = self, self.window != nil else { return } // Only update if view is in window
                    uiViewLogger.debug("[Notification] UIDevice.orientationDidChangeNotification received. Updating preview orientation.")
                    self.updatePreviewOrientation()
            }
             uiViewLogger.info("Setup orientation observer.")
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds // Ensure preview layer fills the view
            previewLayer.cornerRadius = cornerRadius // Maintain corner radius
            uiViewLogger.debug("LayoutSubviews called, updated previewLayer frame and cornerRadius.")
        }
        
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if self.window != nil {
                uiViewLogger.debug("[didMoveToWindow] View added to window. Orientation should be handled by observer or init.")
                // Orientation is handled by observer and initial setup
            }
        }
        
        // MARK: - Frame Management
        
        func updateFrameSize() {
            // Use animation to prevent abrupt changes
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            
            // Calculate the frame that covers the entire screen
            let screenBounds = UIScreen.main.bounds
            let frame = CGRect(x: 0, y: 0, width: screenBounds.width, height: screenBounds.height)
            
            // Update view frame
            self.frame = frame
            
            // Update preview layer frame
            previewLayer.frame = bounds
            
            // Ensure corners stay rounded
            previewLayer.cornerRadius = cornerRadius
            
            // Force portrait orientation
            if let connection = previewLayer.connection {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
            
            // Update LUT overlay layer if it exists
            if let overlay = previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                overlay.frame = bounds
                overlay.cornerRadius = cornerRadius
            }
            
            CATransaction.commit()
        }
        
        // Method to ensure LUT overlay has correct orientation
        func updateLUTOverlayOrientation() {
            // Force portrait orientation for preview layer
            if let connection = previewLayer.connection {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
            
            // Ensure data output connection has correct orientation
            if let dataOutput = dataOutput, let connection = dataOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
            
            // Update overlay to match preview layer orientation
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let overlay = self.previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                    // No need to modify overlay properties, just ensure underlying connections are correct
                    print("DEBUG: Ensured LUT overlay orientation is correct (90°)")
                }
            }
        }
        
        func updateState(newTimestamp: Date, newFilter: CIFilter?) {
            uiViewLogger.debug("--> updateState called. Timestamp: \(newTimestamp), Filter active: \(newFilter != nil ? "Yes" : "No")")
            
            let filterChanged = (self.currentLUTFilter == nil && newFilter != nil) || (self.currentLUTFilter != nil && newFilter == nil) ||
                              (self.currentLUTFilter != nil && newFilter != nil && self.currentLUTFilter != newFilter) // Basic check if filter instance changed
            
            // Update LUT filter
            self.currentLUTFilter = newFilter

            // Check if lens switch timestamp has changed OR if the filter just became active
            if lastProcessedLensSwitchTimestamp != newTimestamp || filterChanged {
                if lastProcessedLensSwitchTimestamp != newTimestamp {
                    uiViewLogger.debug("    [updateState] Timestamp changed (\(self.lastProcessedLensSwitchTimestamp?.description ?? "nil") -> \(newTimestamp)). Lens Switch Detected.")
                    lastProcessedLensSwitchTimestamp = newTimestamp
                    // Explicitly remove overlay during lens switch to prevent flash
                    uiViewLogger.debug("    [updateState] Removing LUT overlay due to lens switch.")
                    removeLUTOverlay()
                }
                if filterChanged {
                     uiViewLogger.debug("    [updateState] Filter changed (or became active/inactive). Calling updatePreviewOrientation.")
                }
                updatePreviewOrientation() // Update orientation on timestamp change OR filter becoming active
            } else {
                uiViewLogger.debug("    [updateState] Timestamp and Filter state (active/inactive) unchanged. Not updating preview orientation.")
            }
        }
        
        func updateLUT(_ filter: CIFilter?) {
            self.currentLUTFilter = filter
        }
        
        // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
        
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            // Reduce logging frequency
            guard VideoOutputDelegate.frameCounter % 60 == 0 else { return }
            uiViewLogger.debug("--> CustomPreviewView captureOutput (Frame: \(VideoOutputDelegate.frameCounter))")

            guard let currentLUTFilter = currentLUTFilter,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                // Log only if LUT *should* be active but buffer is missing
                if currentLUTFilter != nil {
                    uiViewLogger.warning("    [captureOutput] LUT Filter exists but failed to get pixel buffer.")
                    // Ensure overlay is removed if filter is active but buffer fails
                    DispatchQueue.main.async { [weak self] in
                        self?.removeLUTOverlay()
                    }
                }
                // Clear existing overlay if LUT is disabled
                DispatchQueue.main.async { [weak self] in
                    self?.removeLUTOverlay()
                }
                return // Exit if no LUT filter or no pixel buffer
            }

            uiViewLogger.debug("    [captureOutput] LUT Filter ACTIVE. Processing frame.")
            // Create CIImage from the pixel buffer
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

            // Apply LUT filter to the *original* (non-manually-rotated) image
            currentLUTFilter.setValue(ciImage, forKey: kCIInputImageKey)

            guard let outputImage = currentLUTFilter.outputImage else {
                uiViewLogger.error("    [captureOutput] Failed to apply LUT filter to image.") // Updated log message
                return
            }
            
            // Render the final image using the context
            // Use the extent of the processed image, which includes rotation
            let originalWidth = CVPixelBufferGetWidth(pixelBuffer)
            let originalHeight = CVPixelBufferGetHeight(pixelBuffer)
            let targetRect = CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight)
            
            guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
                 uiViewLogger.error("    [captureOutput] Failed create CGImage from filtered output.")
                 return
            }

            uiViewLogger.debug("    [captureOutput] CGImage created. Preparing to update overlay on main thread.")
            // Create or update overlay on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.uiViewLogger.debug("    [captureOutput] Running on main thread to update LUTOverlayLayer.")
                
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                
                // Get the screen bounds
                let viewBounds = self.bounds // Use view bounds for overlay frame

                // Update existing overlay or create a new one
                if let overlay = self.previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                    overlay.contents = cgImage
                    overlay.frame = viewBounds // Use view bounds
                    overlay.cornerRadius = self.cornerRadius
                    overlay.masksToBounds = true // Ensure masking applies after transform
                    
                    // *** IMPORTANT: Reset any layer transform on the overlay itself ***
                    // The content (cgImage) is now pre-rotated. The layer should match the previewLayer exactly.
                    overlay.transform = CATransform3DIdentity
                    
                } else {
                    let overlayLayer = CALayer()
                    overlayLayer.name = "LUTOverlayLayer"
                    overlayLayer.frame = viewBounds // Use view bounds
                    overlayLayer.contentsGravity = .resizeAspectFill
                    overlayLayer.contents = cgImage
                    overlayLayer.cornerRadius = self.cornerRadius
                    overlayLayer.masksToBounds = true
                    
                    // *** Ensure orientation is correct JUST before adding first overlay ***
                    self.updatePreviewOrientation()
                    uiViewLogger.debug("    [captureOutput] Called updatePreviewOrientation just before adding first overlay.")

                    self.previewLayer.addSublayer(overlayLayer)

                    // REMOVED - Redundant with updatePreviewOrientation call in updateState
                }
                
                CATransaction.commit()
                self.uiViewLogger.debug("    [captureOutput] Finished updating LUTOverlayLayer on main thread.")
            }
        }
        
        // Helper to remove LUT overlay if LUT is disabled
        private func removeLUTOverlay() {
            if let overlay = previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                uiViewLogger.debug("    [removeLUTOverlay] Removing LUTOverlayLayer.")
                overlay.removeFromSuperlayer()
            }
        }
        
        // Completely prevent any transform-based animations
        override func action(for layer: CALayer, forKey event: String) -> CAAction? {
            if event == "transform" || event == "position" || event == "bounds" {
                return NSNull()
            }
            return super.action(for: layer, forKey: event)
        }
        
        func updatePreviewOrientation() {
            uiViewLogger.debug("--> updatePreviewOrientation called")
            guard let previewConnection = previewLayer.connection else {
                uiViewLogger.warning("    [updatePreviewOrientation] PreviewLayer has no connection.")
                return
            }
            
            let newAngle: CGFloat
            let deviceOrientation = UIDevice.current.orientation
            let interfaceOrientation = window?.windowScene?.interfaceOrientation ?? .portrait
            
            // Prioritize valid device orientation
            if deviceOrientation.isValidInterfaceOrientation {
                switch deviceOrientation {
                    case .portrait: newAngle = 90
                    case .landscapeLeft: newAngle = 180 // Phone physical top points left (Interface Landscape Left)
                    case .landscapeRight: newAngle = 0   // Phone physical top points right (Interface Landscape Right)
                    case .portraitUpsideDown: newAngle = 270
                    default: newAngle = 90 // Should not happen
                }
                 uiViewLogger.debug("    [updatePreviewOrientation] Using Device Orientation: \(deviceOrientation.rawValue)")
            } else {
                // Fallback to interface orientation if device orientation is invalid (face up/down/unknown)
                switch interfaceOrientation {
                    case .portrait: newAngle = 90
                    case .landscapeLeft: newAngle = 180 // Interface left means phone top points right
                    case .landscapeRight: newAngle = 0 // Interface right means phone top points left
                    case .portraitUpsideDown: newAngle = 270
                    default: newAngle = 90 // Unknown
                }
                uiViewLogger.debug("    [updatePreviewOrientation] Using Interface Orientation: \(interfaceOrientation.rawValue)")
            }
            
            // Update the stored angle for captureOutput buffer rotation
            self.currentRotationAngle = newAngle
            uiViewLogger.info("    [updatePreviewOrientation] Stored currentRotationAngle for buffer processing: \(newAngle)°")

            // --- Update Preview Layer Connection Only ---
            let currentPreviewAngle = previewConnection.videoRotationAngle
            uiViewLogger.debug("    [updatePreviewOrientation] Current PREVIEW angle: \(currentPreviewAngle)°, Target angle: \(newAngle)°")

            if previewConnection.isVideoRotationAngleSupported(newAngle) {
                if previewConnection.videoRotationAngle != newAngle {
                    previewConnection.videoRotationAngle = newAngle
                    uiViewLogger.info("    [updatePreviewOrientation] Updated PREVIEW layer connection angle to \(newAngle)°")
                } else {
                    uiViewLogger.debug("    [updatePreviewOrientation] PREVIEW layer connection angle already \(newAngle)°. No change.")
                }
            } else {
                uiViewLogger.warning("    [updatePreviewOrientation] Angle \(newAngle)° not supported for PREVIEW layer connection.")
            }
            
            // --- REMOVED Data Output Connection Update ---
            // We are now rotating the buffer manually in captureOutput based on currentRotationAngle
            /*
            if let dataOutputConnection = dataOutput?.connection(with: .video) {
                // ... removed code ...
            } else {
                uiViewLogger.warning("    [updatePreviewOrientation] Could not get DATA output connection.")
            }
            */
            // --- Restore Data Output Connection Update ---
            if let dataOutputConnection = dataOutput?.connection(with: .video) {
                let currentDataAngle = dataOutputConnection.videoRotationAngle
                uiViewLogger.debug("    [updatePreviewOrientation] Current DATA angle: \(currentDataAngle)°, Target angle: \(newAngle)°")
                if dataOutputConnection.isVideoRotationAngleSupported(newAngle) {
                     if dataOutputConnection.videoRotationAngle != newAngle {
                         dataOutputConnection.videoRotationAngle = newAngle
                         uiViewLogger.info("    [updatePreviewOrientation] Updated DATA output connection angle to \(newAngle)°")
                     } else {
                         uiViewLogger.debug("    [updatePreviewOrientation] DATA output connection angle already \(newAngle)°. No change.")
                     }
                } else {
                    uiViewLogger.warning("    [updatePreviewOrientation] Angle \(newAngle)° not supported for DATA output connection.")
                }
            } else {
                uiViewLogger.warning("    [updatePreviewOrientation] Could not get DATA output connection.")
            }
            uiViewLogger.debug("<-- Finished updatePreviewOrientation")
        }
    }
}
