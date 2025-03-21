import SwiftUI
import AVFoundation
import CoreImage

struct LUTVideoPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel
    
    func makeUIView(context: Context) -> LUTPreviewView {
        // Allow rotation instead of locking to portrait
        CameraOrientationLock.unlockForRotation()
        
        // Create the preview view
        let previewView = LUTPreviewView()
        
        // Connect the session - this will use our backing layer approach
        previewView.setSession(session)
        
        // Set up video data output for LUT processing
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(context.coordinator, queue: DispatchQueue(label: "videoQueue"))
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            
            // Set appropriate orientation for video connection - always portrait
            if let connection = videoOutput.connection(with: .video) {
                // Always use portrait orientation (90°) for camera preview
                let rotationAngle: CGFloat = 90
                
                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                    print("🔒 LUT VIDEO PREVIEW - Locked to portrait orientation (90°)")
                }
            }
        }
        
        // Store references in coordinator
        context.coordinator.previewView = previewView
        context.coordinator.session = session
        
        // Register for orientation change notifications to adjust preview
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        
        // Register for orientation will change notification to prevent position shifts
        NotificationCenter.default.addObserver(
            previewView,
            selector: #selector(previewView.orientationWillChange),
            name: UIScene.willEnterForegroundNotification,
            object: nil
        )
        
        return previewView
    }
    
    func updateUIView(_ uiView: LUTPreviewView, context: Context) {
        // Update LUT filter
        context.coordinator.lutProcessor.setLUTFilter(lutManager.currentLUTFilter)
        
        // Update log mode
        context.coordinator.lutProcessor.setLogEnabled(viewModel.isAppleLogEnabled)
        
        // Update the preview view's LUT status
        uiView.isLUTEnabled = lutManager.currentLUTFilter != nil
        
        // Update orientation after any property changes
        uiView.updateOrientation()
    }
    
    static func dismantleUIView(_ uiView: LUTPreviewView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        NotificationCenter.default.removeObserver(uiView)
        
        // Unlock orientation when view is dismantled
        CameraOrientationLock.unlockForRotation()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let parent: LUTVideoPreviewView
        var session: AVCaptureSession?
        weak var previewView: LUTPreviewView?
        let lutProcessor = LUTProcessor()
        
        // Track the current device orientation to detect landscape transitions
        private var lastDeviceOrientation: UIDeviceOrientation = .portrait
        
        init(parent: LUTVideoPreviewView) {
            self.parent = parent
            super.init()
            
            // Initialize the LUT processor with the current LUT filter
            lutProcessor.setLUTFilter(parent.lutManager.currentLUTFilter)
            lutProcessor.setLogEnabled(parent.viewModel.isAppleLogEnabled)
            
            // Allow rotation instead of locking to portrait
            CameraOrientationLock.unlockForRotation()
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        @objc func deviceOrientationDidChange() {
            // Get device orientation for logging only
            let deviceOrientation = UIDevice.current.orientation
            
            print("🔒 LUT ORIENTATION CHANGE - Device orientation changed to: \(deviceOrientation.rawValue)")
            
            // Allow rotation and update the preview based on the new orientation
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // Allow system UI rotation
                CameraOrientationLock.unlockForRotation()
                
                // But keep video preview locked to portrait
                if let connection = self.session?.outputs.first as? AVCaptureVideoDataOutput,
                   let videoConnection = connection.connection(with: .video) {
                    // Always use portrait orientation (90°)
                    let rotationAngle: CGFloat = 90
                    
                    if videoConnection.isVideoRotationAngleSupported(rotationAngle) {
                        videoConnection.videoRotationAngle = rotationAngle
                        print("🔒 LUT VIDEO CONNECTION - Locked to portrait orientation (90°)")
                    }
                }
                
                // Update the preview layer orientation
                self.previewView?.updateOrientation()
            }
        }
        
        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            // Always use portrait orientation (90°) for all video processing
            let rotationAngle: CGFloat = 90
            
            // Apply the portrait orientation to the connection
            if connection.isVideoRotationAngleSupported(rotationAngle) && connection.videoRotationAngle != rotationAngle {
                connection.videoRotationAngle = rotationAngle
                print("🔒 LUT CAPTURE OUTPUT - Locked to portrait orientation (90°)")
            }
            
            // Only process if LUT is enabled
            if parent.lutManager.currentLUTFilter != nil {
                // Get the pixel buffer from the sample buffer
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    print("❌ Failed to get pixel buffer from sample buffer")
                    return
                }
                
                // Create a CIImage from the pixel buffer
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                
                // Process the image with the LUT
                if let processedImage = lutProcessor.processImage(ciImage),
                   let cgImage = lutProcessor.createCGImage(from: processedImage) {
                    // Update the preview view with the processed frame
                    DispatchQueue.main.async { [weak self] in
                        self?.previewView?.displayProcessedImage(cgImage)
                    }
                }
            } else {
                // If no LUT is enabled, hide the processed view layer
                DispatchQueue.main.async { [weak self] in
                    self?.previewView?.hideProcessedLayer()
                }
            }
        }
    }
}

/// A UIView subclass that uses AVCaptureVideoPreviewLayer as its backing layer
class LUTPreviewView: UIView {
    private var processedLayer: CALayer?
    private var isHandlingRotation = false
    
    var isLUTEnabled: Bool = false {
        didSet {
            if isLUTEnabled != oldValue {
                if isLUTEnabled {
                    // Show the processed layer and hide the preview layer
                    processedLayer?.isHidden = false
                    layer.isHidden = true
                } else {
                    // Show the preview layer and hide the processed layer
                    processedLayer?.isHidden = true
                    layer.isHidden = false
                }
            }
        }
    }
    
    // Use the preview layer as the view's backing layer
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
    
    // Access the layer as an AVCaptureVideoPreviewLayer
    var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
    
    // Disable autoresizing to prevent automatic frame changes during rotation
    override var translatesAutoresizingMaskIntoConstraints: Bool {
        get { return false }
        set { /* no-op to prevent changes */ }
    }
    
    // Override transform to prevent any rotation
    override var transform: CGAffineTransform {
        get { return .identity }
        set { /* no-op to prevent changes */ }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
        
        // Disable automatic transformations during rotation
        autoresizingMask = []
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
        
        // Disable automatic transformations during rotation
        autoresizingMask = []
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupLayers() {
        // Disable implicit animations to prevent unwanted transitions
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // Configure the preview layer (which is our backing layer)
        previewLayer.videoGravity = .resizeAspectFill
        
        // Create a layer for displaying the processed frames
        let processedCALayer = CALayer()
        processedCALayer.frame = bounds
        processedCALayer.contentsGravity = .resizeAspectFill
        processedCALayer.isHidden = true // Initially hidden
        layer.addSublayer(processedCALayer)
        processedLayer = processedCALayer
        
        CATransaction.commit()
        
        // Update orientation based on device orientation
        updateOrientation()
    }
    
    func setSession(_ session: AVCaptureSession) {
        // Set the session on the preview layer
        previewLayer.session = session
        
        // Update orientation based on device orientation
        updateOrientation()
    }
    
    // Called just before orientation changes
    @objc func orientationWillChange(_ notification: Notification) {
        isHandlingRotation = true
        // Lock everything in place during rotation
        lockViewDuringRotation()
    }
    
    private func lockViewDuringRotation() {
        // Disable animations
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        
        // Reset any transforms
        previewLayer.transform = CATransform3DIdentity
        processedLayer?.transform = CATransform3DIdentity
        
        // Force our own positioning
        if let superview = superview {
            frame = CGRect(x: 0, y: 0, width: superview.bounds.width, height: superview.bounds.height)
        }
        
        // Ensure processed layer stays fixed
        if let processedLayer = processedLayer {
            processedLayer.frame = bounds
        }
        
        CATransaction.commit()
        
        // Update orientation
        updateOrientation()
        
        // Re-enable normal handling after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isHandlingRotation = false
        }
    }
    
    func updateOrientation() {
        // Get device orientation for logging only
        let deviceOrientation = UIDevice.current.orientation
        
        // Log the current orientation and frame dimensions
        print("🔒 LUT ORIENTATION UPDATE - Device orientation: \(deviceOrientation.rawValue)")
        print("📏 LUT PREVIEW FRAME - Frame: \(frame), Bounds: \(bounds)")
        
        // Update the preview layer orientation - always use portrait
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        if let connection = previewLayer.connection {
            // Always use portrait orientation (90°)
            let rotationAngle: CGFloat = 90
            
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
                print("🔒 LUT PREVIEW LAYER - Locked to portrait orientation (90°)")
            } else {
                print("⚠️ Rotation angle 90° not supported on preview layer connection")
            }
        }
        
        // Update processed layer frame to match bounds
        if let processedLayer = processedLayer {
            processedLayer.frame = bounds
        }
        
        CATransaction.commit()
    }
    
    func ensureFixedOrientation() {
        // Get device orientation for logging only
        let deviceOrientation = UIDevice.current.orientation
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        if let connection = previewLayer.connection {
            // Always use portrait orientation (90°)
            let rotationAngle: CGFloat = 90
            
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                let currentAngle = connection.videoRotationAngle
                if currentAngle != rotationAngle {
                    connection.videoRotationAngle = rotationAngle
                    print("🔒 LUT PREVIEW CORRECTED - From \(currentAngle)° to 90° (portrait)")
                } else {
                    print("✅ LUT PREVIEW CORRECT - Already at portrait orientation (90°)")
                }
            } else {
                print("⚠️ Rotation angle 90° not supported on preview layer connection")
            }
        }
        
        // Ensure the layer's transform is identity to prevent any rotation
        previewLayer.transform = CATransform3DIdentity
        processedLayer?.transform = CATransform3DIdentity
        
        // Apply additional transforms to counteract any rotation effects
        if deviceOrientation == .portraitUpsideDown {
            // For upside-down orientation, we need to ensure the view doesn't flip
            print("📱 Applying additional fixes for upside-down orientation")
            
            // Force our own positioning to stay centered in the superview
            if let superview = superview {
                center = CGPoint(x: superview.bounds.width/2, y: superview.bounds.height/2)
            }
        }
        
        CATransaction.commit()
    }
    
    func displayProcessedImage(_ image: CGImage) {
        // Disable implicit animations when updating content
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        processedLayer?.contents = image
        
        CATransaction.commit()
    }
    
    func hideProcessedLayer() {
        // Disable implicit animations
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        processedLayer?.isHidden = true
        layer.isHidden = false
        
        CATransaction.commit()
        
        // Update orientation when switching back to preview layer
        updateOrientation()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        if !isHandlingRotation {
            // Completely disable any layout changes during rotation
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setAnimationDuration(0)
            
            processedLayer?.frame = bounds
            
            // Ensure the layer's transform is identity to prevent any rotation
            previewLayer.transform = CATransform3DIdentity
            processedLayer?.transform = CATransform3DIdentity
            
            CATransaction.commit()
            
            // Update orientation after layout changes
            updateOrientation()
        }
    }
    
    // Override to prevent automatic transforms during rotation
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateOrientation()
    }
    
    // Override to prevent bounds changes from affecting layout
    override var bounds: CGRect {
        didSet {
            if !isHandlingRotation && bounds != oldValue {
                updateOrientation()
            }
        }
    }
    
    // Override to prevent frame changes from affecting layout
    override var frame: CGRect {
        didSet {
            if !isHandlingRotation && frame != oldValue {
                updateOrientation()
            }
        }
    }
} 