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
            // Update LUT if needed - just pass the reference, don't modify
            preview.updateLUT(lutManager.currentLUTFilter)
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
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: topAnchor, constant: borderWidth),
                contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -borderWidth),
                contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: borderWidth),
                contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -borderWidth)
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
                Task { @MainActor in
                    volumeButtonHandler?.detachFromView(self)
                }
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
                contentView.frame = bounds.inset(by: UIEdgeInsets(top: borderWidth,
                                                                left: borderWidth,
                                                                bottom: borderWidth,
                                                                right: borderWidth))
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
        var viewModel: CameraViewModel  // Changed to internal access
        private var ciContext = CIContext(options: [.useSoftwareRenderer: false])
        private let processingQueue = DispatchQueue(label: "com.camera.lutprocessing", qos: .userInitiated)
        private var currentLUTFilter: CIFilter?
        private let cornerRadius: CGFloat = 20.0
        
        init(frame: CGRect, session: AVCaptureSession, lutManager: LUTManager, viewModel: CameraViewModel) {
            self.session = session
            self.lutManager = lutManager
            self.viewModel = viewModel
            self.previewLayer = AVCaptureVideoPreviewLayer()
            super.init(frame: frame)
            setupView()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setupView() {
            // Disable autoresizing mask
            autoresizingMask = []
            translatesAutoresizingMaskIntoConstraints = false
            
            // Configure preview layer
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.cornerRadius = 20 // Add rounded corners
            previewLayer.masksToBounds = true
            
            // Add preview layer
            layer.addSublayer(previewLayer)
            
            // Add rounded corners to the view itself
            layer.cornerRadius = 20
            layer.masksToBounds = true
            
            print("DEBUG: CustomPreviewView setupView - Initial frame: \(frame)")
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            print("DEBUG: CustomPreviewView layoutSubviews - Frame: \(frame), Bounds: \(bounds)")
            
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            
            // Ensure corners stay rounded
            previewLayer.cornerRadius = cornerRadius
            layer.cornerRadius = cornerRadius
            
            print("DEBUG: PreviewLayer frame set to: \(previewLayer.frame)")
            CATransaction.commit()
        }
        
        func updateFrameSize() {
            // Use animation to prevent abrupt changes
            CATransaction.begin()
            CATransaction.setDisableActions(true)  // Disable animations for stability
            
            // Keep the same frame dimensions - don't update based on container
            let currentBounds = bounds
            previewLayer.frame = currentBounds
            
            // Ensure corners stay rounded after frame updates
            previewLayer.cornerRadius = cornerRadius
            
            // Force portrait orientation
            if let connection = previewLayer.connection {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
            
            // Also update any LUT overlay layer
            if let overlay = previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                overlay.frame = previewLayer.bounds
                overlay.cornerRadius = cornerRadius
            }
            
            CATransaction.commit()
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
            
            // Create an overlay image
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.3)
                
                // Update existing overlay or create a new one
                if let overlay = self.previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                    overlay.contents = cgImage
                    overlay.cornerRadius = self.cornerRadius  // Apply corner radius to LUT overlay
                } else {
                    let overlayLayer = CALayer()
                    overlayLayer.name = "LUTOverlayLayer"
                    overlayLayer.frame = self.previewLayer.bounds
                    overlayLayer.contentsGravity = .resizeAspectFill
                    overlayLayer.contents = cgImage
                    overlayLayer.cornerRadius = self.cornerRadius  // Apply corner radius to new LUT overlay
                    overlayLayer.masksToBounds = true
                    self.previewLayer.addSublayer(overlayLayer)
                    print("DEBUG: Added LUT overlay layer")
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
