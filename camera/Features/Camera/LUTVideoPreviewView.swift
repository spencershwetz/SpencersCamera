import SwiftUI
import AVFoundation
import CoreImage

struct LUTVideoPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel
    
    func makeUIView(context: Context) -> LUTPreviewView {
        // Lock the orientation to portrait
        CameraOrientationLock.lockToPortrait()
        
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
            
            // Set fixed orientation for video connection
            if let connection = videoOutput.connection(with: .video) {
                // Set rotation angle to 90 degrees (portrait)
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                    print("📱 Video connection fixed to portrait orientation (90°)")
                }
            }
        }
        
        // Store references in coordinator
        context.coordinator.previewView = previewView
        context.coordinator.session = session
        
        // Register for orientation change notifications to ensure preview stays fixed
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
        // Update LUT filter in processor if it changed
        context.coordinator.lutProcessor.setLUTFilter(lutManager.currentLUTFilter)
        
        // Update LOG mode in processor if it changed
        context.coordinator.lutProcessor.setLogEnabled(viewModel.isAppleLogEnabled)
        
        // Update the preview view's LUT status
        uiView.isLUTEnabled = lutManager.currentLUTFilter != nil
        
        // Ensure preview layer orientation is fixed
        uiView.ensureFixedOrientation()
    }
    
    static func dismantleUIView(_ uiView: LUTPreviewView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        NotificationCenter.default.removeObserver(uiView)
        
        // Unlock orientation when view is dismantled
        CameraOrientationLock.unlock()
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
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        @objc func deviceOrientationDidChange() {
            let currentOrientation = UIDevice.current.orientation
            print("🔄 Device orientation changed to: \(currentOrientation.rawValue)")
            
            // Ensure the preview stays fixed in portrait
            DispatchQueue.main.async { [weak self] in
                // Re-lock to portrait orientation
                CameraOrientationLock.lockToPortrait()
                
                // Ensure connections are using the correct rotation angle
                if let connection = self?.session?.outputs.first as? AVCaptureVideoDataOutput,
                   let videoConnection = connection.connection(with: .video),
                   videoConnection.isVideoRotationAngleSupported(90) {
                    videoConnection.videoRotationAngle = 90  // 90° = portrait
                }
                
                // Ensure the preview layer orientation is fixed
                self?.previewView?.ensureFixedOrientation()
            }
        }
        
        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            // Ensure connection orientation stays fixed to 90 degrees (portrait)
            if connection.isVideoRotationAngleSupported(90) && connection.videoRotationAngle != 90 {
                connection.videoRotationAngle = 90
                print("📱 Reset video connection to portrait (90°) in captureOutput")
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
        
        // Ensure orientation is fixed
        ensureFixedOrientation()
    }
    
    func setSession(_ session: AVCaptureSession) {
        // Set the session on the preview layer
        previewLayer.session = session
        
        // Ensure orientation is fixed
        ensureFixedOrientation()
    }
    
    // Called just before orientation changes
    @objc func orientationWillChange(_ notification: Notification) {
        isHandlingRotation = true
        // Lock everything in place
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
        
        // Re-apply orientation fix
        ensureFixedOrientation()
        
        // Re-enable normal handling after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isHandlingRotation = false
        }
    }
    
    func ensureFixedOrientation() {
        // Ensure the preview layer's orientation is fixed to portrait (90 degrees)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        if let connection = previewLayer.connection {
            if connection.isVideoRotationAngleSupported(90) {
                let currentAngle = connection.videoRotationAngle
                if currentAngle != 90 {
                    connection.videoRotationAngle = 90
                    print("🔄 Preview layer orientation corrected from \(currentAngle)° to 90°")
                } else {
                    print("✅ Preview layer already in portrait orientation (90°)")
                }
            } else {
                print("⚠️ Video rotation angle not supported on preview layer connection")
            }
        }
        
        // Ensure the layer's transform is identity to prevent any rotation
        previewLayer.transform = CATransform3DIdentity
        processedLayer?.transform = CATransform3DIdentity
        
        // Apply additional transforms to counteract any rotation effects
        if UIDevice.current.orientation == .portraitUpsideDown {
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
        
        // Ensure orientation is fixed when switching back to preview layer
        ensureFixedOrientation()
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
            
            // Ensure orientation stays fixed after layout changes
            ensureFixedOrientation()
        }
    }
    
    // Override to prevent automatic transforms during rotation
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        ensureFixedOrientation()
    }
    
    // Override to prevent bounds changes from affecting layout
    override var bounds: CGRect {
        didSet {
            if !isHandlingRotation && bounds != oldValue {
                ensureFixedOrientation()
            }
        }
    }
    
    // Override to prevent frame changes from affecting layout
    override var frame: CGRect {
        didSet {
            if !isHandlingRotation && frame != oldValue {
                ensureFixedOrientation()
            }
        }
    }
} 