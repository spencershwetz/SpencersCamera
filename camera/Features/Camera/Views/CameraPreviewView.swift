import SwiftUI
import AVFoundation
import CoreImage
import AVKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel
    
    func makeUIView(context: Context) -> RotationLockedContainer {
        print("DEBUG: Creating CameraPreviewView")
        
        // Create container with explicit bounds
        let screen = UIScreen.main.bounds
        let container = RotationLockedContainer(contentView: CustomPreviewView(frame: screen, 
                                                                              session: session, 
                                                                              lutManager: lutManager,
                                                                              viewModel: viewModel))
        
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
        private var ciContext = CIContext(options: [.useSoftwareRenderer: false])
        private let processingQueue = DispatchQueue(label: "com.camera.lutprocessing", qos: .userInitiated)
        private var currentLUTFilter: CIFilter?
        private let cornerRadius: CGFloat = 20.0
        private var lastProcessedLensSwitchTimestamp: Date?
        
        init(frame: CGRect, session: AVCaptureSession, lutManager: LUTManager, viewModel: CameraViewModel) {
            self.session = session
            self.lutManager = lutManager
            self.viewModel = viewModel
            self.previewLayer = AVCaptureVideoPreviewLayer()
            super.init(frame: frame)
            setupView()
            setupPreviewLayer()
            setupVideoDataOutput()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setupView() {
            // Set tag for lookup in updateUIView
            tag = 100
            
            // Apply corner radius
            layer.cornerRadius = cornerRadius
            layer.masksToBounds = true
            
            // Set background color to black
            backgroundColor = .black
        }
        
        private func setupPreviewLayer() {
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(previewLayer)
        }
        
        private func setupVideoDataOutput() {
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
        
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds // Ensure preview layer fills the view
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
            // Update LUT filter
            self.currentLUTFilter = newFilter
            
            // Check if lens switch timestamp has changed
            if lastProcessedLensSwitchTimestamp != newTimestamp {
                print("DEBUG: [CustomPreviewView] Detected lens switch timestamp change. Updating preview orientation.")
                updatePreviewOrientation()
                lastProcessedLensSwitchTimestamp = newTimestamp
            } else {
                print("DEBUG: [CustomPreviewView] Timestamp unchanged. Not updating preview orientation.")
            }
        }
        
        func updateLUT(_ filter: CIFilter?) {
            self.currentLUTFilter = filter
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
        
        func updatePreviewOrientation() {
            guard let connection = previewLayer.connection else {
                print("DEBUG: PreviewLayer has no connection to update orientation.")
                return
            }
            
            let newAngle: CGFloat
            let deviceOrientation = UIDevice.current.orientation
            let interfaceOrientation = window?.windowScene?.interfaceOrientation ?? .portrait
            
            if deviceOrientation.isValidInterfaceOrientation {
                switch deviceOrientation {
                case .portrait: newAngle = 90
                case .landscapeLeft: newAngle = 0
                case .landscapeRight: newAngle = 180
                case .portraitUpsideDown: newAngle = 270
                default: newAngle = 90
                }
            } else {
                switch interfaceOrientation {
                case .portrait: newAngle = 90
                case .landscapeLeft: newAngle = 0
                case .landscapeRight: newAngle = 180
                case .portraitUpsideDown: newAngle = 270
                default: newAngle = 90
                }
            }
            
            if connection.isVideoRotationAngleSupported(newAngle) {
                if connection.videoRotationAngle != newAngle {
                    connection.videoRotationAngle = newAngle
                    print("DEBUG: [CustomPreviewView] Updated PREVIEW layer connection angle to \(newAngle)°")
                } else {
                    print("DEBUG: [CustomPreviewView] PREVIEW layer connection angle already \(newAngle)°. No change.")
                }
            } else {
                print("DEBUG: [CustomPreviewView] Angle \(newAngle)° not supported for PREVIEW layer connection.")
            }
        }
    }
}
