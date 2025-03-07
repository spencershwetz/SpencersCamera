import SwiftUI
import AVFoundation
import CoreImage

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel
    
    func makeUIView(context: Context) -> RotationLockedContainer {
        print("DEBUG: Creating CameraPreviewView")
        // Create a rotation-locked container to hold our preview
        let container = RotationLockedContainer(frame: UIScreen.main.bounds)
        
        // Store reference to this container in the view model for LUT processing
        viewModel.owningView = container
        
        // Create a custom preview view that will handle LUT processing
        let preview = CustomPreviewView(frame: UIScreen.main.bounds, 
                                       session: session, 
                                       lutManager: lutManager,
                                       viewModel: viewModel)
        preview.backgroundColor = .black
        preview.tag = 100 // Tag for identification
        
        // Add the preview to our container
        container.addSubview(preview)
        
        // Pin the preview to the container with auto layout
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            preview.leftAnchor.constraint(equalTo: container.leftAnchor),
            preview.rightAnchor.constraint(equalTo: container.rightAnchor)
        ])
        
        return container
    }
    
    func updateUIView(_ uiView: RotationLockedContainer, context: Context) {
        // Verify session is running
        if !session.isRunning {
            print("DEBUG: Camera session NOT running during update! Starting...")
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
                DispatchQueue.main.async {
                    print("DEBUG: Camera session started in updateUIView: \(self.session.isRunning)")
                }
            }
        }
        
        // Re-enforce the fixed frame and rotation settings
        uiView.frame = UIScreen.main.bounds
        
        // Find and update the preview view
        if let preview = uiView.viewWithTag(100) as? CustomPreviewView {
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
        override init(frame: CGRect) {
            super.init(frame: frame)
            setupView()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupView()
        }
        
        private func setupView() {
            // Basics
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            backgroundColor = .black
            clipsToBounds = true
            
            // Register for orientation changes
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(orientationDidChange),
                name: UIDevice.orientationDidChangeNotification,
                object: nil
            )
            
            // Use modern approach to detect size changes - observe view bounds
            NotificationCenter.default.addObserver(
                self, 
                selector: #selector(interfaceOrientationDidChange),
                name: UIWindow.didBecomeVisibleNotification, 
                object: nil
            )
            
            // Register for trait changes in iOS 17+
            if #available(iOS 17.0, *) {
                registerForTraitChanges([UITraitActiveAppearance.self, UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { [weak self] (view: RotationLockedContainer, previousTraitCollection: UITraitCollection) in
                    self?.enforceBounds()
                }
            }
            
            print("DEBUG: RotationLockedContainer initialized")
        }
        
        @objc private func orientationDidChange() {
            print("DEBUG: Container detected device orientation change")
            enforceBounds()
        }
        
        @objc private func interfaceOrientationDidChange() {
            print("DEBUG: Container detected interface orientation change")
            enforceBounds()
        }
        
        // Also enforce bounds when the view size changes - use updated method for iOS 17+
        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            // Only use this method on iOS 16 and earlier
            if #available(iOS 17.0, *) {
                // We handle this with registerForTraitChanges
            } else {
                enforceBounds()
            }
        }
        
        private func enforceBounds() {
            // Always maintain full screen bounds regardless of rotation
            frame = UIScreen.main.bounds
            
            // Re-enforce rotation settings for all subviews
            for case let preview as CustomPreviewView in subviews {
                preview.frame = bounds
                preview.updateFrameSize()
            }
        }
        
        // Override these methods to prevent rotation from affecting our view
        override func layoutSubviews() {
            super.layoutSubviews()
            enforceBounds()
        }
        
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            enforceBounds()
        }
        
        override func didMoveToWindow() {
            super.didMoveToWindow()
            enforceBounds()
        }
    }
    
    // Custom preview view that handles LUT processing
    class CustomPreviewView: UIView, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let previewLayer = AVCaptureVideoPreviewLayer()
        private var dataOutput: AVCaptureVideoDataOutput?
        private let session: AVCaptureSession
        private var lutManager: LUTManager
        private var viewModel: CameraViewModel
        private var ciContext = CIContext(options: [.useSoftwareRenderer: false])
        private let processingQueue = DispatchQueue(label: "com.camera.lutprocessing", qos: .userInitiated)
        private var currentLUTFilter: CIFilter?
        
        init(frame: CGRect, session: AVCaptureSession, lutManager: LUTManager, viewModel: CameraViewModel) {
            self.session = session
            self.lutManager = lutManager
            self.viewModel = viewModel
            super.init(frame: frame)
            setupView()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setupView() {
            // Configure preview layer
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = bounds
            layer.addSublayer(previewLayer)
            
            // Set initial orientation
            if previewLayer.connection?.isVideoRotationAngleSupported(90) == true {
                previewLayer.connection?.videoRotationAngle = 90
            }
            
            print("DEBUG: CustomPreviewView set up with AVCaptureVideoPreviewLayer")
            
            // Set up data output if LUT filter is available
            if let filter = lutManager.currentLUTFilter {
                setupDataOutput()
                currentLUTFilter = filter
            }
        }
        
        func updateFrameSize() {
            previewLayer.frame = bounds
            
            // Also update connection orientation
            if previewLayer.connection?.isVideoRotationAngleSupported(90) == true {
                previewLayer.connection?.videoRotationAngle = 90
            }
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
                    // Filter removed
                    removeDataOutput()
                }
            }
            
            // Update our local reference only - don't modify published properties
            currentLUTFilter = filter
            
            // DON'T update viewModel.lutManager here - this is called during view updates
            // and would trigger the SwiftUI warning
            
            if filter != nil {
                print("DEBUG: CustomPreviewView updated with LUT filter")
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
                
                // Ensure proper orientation
                if let connection = output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
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
                CATransaction.setDisableActions(true)
                
                // Update existing overlay or create a new one
                if let overlay = self.previewLayer.sublayers?.first(where: { $0.name == "LUTOverlayLayer" }) {
                    overlay.contents = cgImage
                } else {
                    let overlayLayer = CALayer()
                    overlayLayer.name = "LUTOverlayLayer"
                    overlayLayer.frame = self.previewLayer.bounds
                    overlayLayer.contentsGravity = .resizeAspectFill
                    overlayLayer.contents = cgImage
                    self.previewLayer.addSublayer(overlayLayer)
                    print("DEBUG: Added LUT overlay layer")
                }
                
                CATransaction.commit()
            }
        }
    }
}
