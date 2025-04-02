extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Static counter to track frames
        static var frameCount = 0
        frameCount += 1
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        print("📹 Frame received at: \(String(format: "%.3f", timestamp)) - Frame #\(frameCount)")
        print("- Buffer valid: \(CMSampleBufferIsValid(sampleBuffer))")
        print("- Connection enabled: \(connection.isEnabled)")
        print("- Connection active: \(connection.isActive)")
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("⚠️ No pixel buffer in sample buffer")
            return
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        print("✅ Valid frame received - Dimensions: \(width)x\(height)")
        
        // Every 60 frames, log a summary
        if frameCount % 60 == 0 {
            print("🎬 Frame summary: Received \(frameCount) frames successfully")
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Static counter to track dropped frames
        static var droppedFrameCount = 0
        droppedFrameCount += 1
        
        print("⚠️ Dropped frame #\(droppedFrameCount) - Connection enabled: \(connection.isEnabled)")
        
        // Every 10 dropped frames, log more details
        if droppedFrameCount % 10 == 0 {
            print("⚠️ Dropped frame summary: \(droppedFrameCount) frames dropped")
            print("- Connection status: enabled=\(connection.isEnabled), active=\(connection.isActive)")
            print("- Output: \(output)")
            print("- Session running: \(session.isRunning)")
        }
    }
}

extension CameraViewModel: AVCaptureSessionDelegate {
    func captureSessionDidStartRunning(_ session: AVCaptureSession) {
        print("🎥 Capture Session Started Running")
        print("- Inputs: \(session.inputs.count)")
        print("- Outputs: \(session.outputs.count)")
        print("- Running: \(session.isRunning)")
    }
    
    func captureSessionDidStopRunning(_ session: AVCaptureSession) {
        print("🛑 Capture Session Stopped Running")
    }
}

class CameraViewModel: NSObject, ObservableObject {
    public let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.camera.sessionQueue")
    private let videoOutputQueue = DispatchQueue(label: "com.camera.videoOutputQueue", qos: .userInteractive)
    
    // Add a unique ID for tracking
    let instanceId = UUID().uuidString
    
    // Add a published property to monitor session state
    @Published var isSessionRunning: Bool = false
    
    override init() {
        super.init()
        print("🔶 CameraViewModel.init() - Instance ID: \(instanceId)")
        
        // Set up session notifications
        NotificationCenter.default.addObserver(self, 
                                               selector: #selector(sessionRuntimeError), 
                                               name: .AVCaptureSessionRuntimeError, 
                                               object: session)
        
        // Observe session state changes
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(sessionDidStartRunning),
                                             name: .AVCaptureSessionDidStartRunning,
                                             object: session)
        
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(sessionDidStopRunning),
                                             name: .AVCaptureSessionDidStopRunning,
                                             object: session)
        
        // Configure session
        configureSession()
    }
    
    deinit {
        // Clean up observers
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func sessionDidStartRunning(_ notification: Notification) {
        DispatchQueue.main.async {
            self.isSessionRunning = true
            print("📢 Session started running - Updated isSessionRunning to \(self.isSessionRunning)")
        }
    }
    
    @objc private func sessionDidStopRunning(_ notification: Notification) {
        DispatchQueue.main.async {
            self.isSessionRunning = false
            print("📢 Session stopped running - Updated isSessionRunning to \(self.isSessionRunning)")
        }
    }
    
    // Handle session runtime errors
    @objc private func sessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        print("⚠️ Capture session runtime error: \(error.localizedDescription)")
        
        // Try to recover
        if error.code == .mediaServicesWereReset {
            sessionQueue.async { [weak self] in
                self?.session.startRunning()
            }
        }
    }
    
    private func configureSession() {
        print("🎥 Configuring capture session")
        
        // Use a background queue with high priority for setup
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            self.session.beginConfiguration()
            
            do {
                // Add video input
                if let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                    print("📷 Selected video device: \(videoDevice.localizedName)")
                    print("- Device active: \(videoDevice.isConnected)")
                    print("- Device suspended: \(videoDevice.isSuspended)")
                    
                    let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                    if self.session.canAddInput(videoInput) {
                        self.session.addInput(videoInput)
                        print("✅ Added video input")
                    } else {
                        print("⚠️ Could not add video input")
                    }
                }
                
                // Configure video output
                self.videoOutput.videoSettings = [(kCVPixelBufferPixelFormatTypeKey as String): Int(kCVPixelFormatType_32BGRA)]
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                
                // Set up video output queue and delegate
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)
                print("🎥 Video Output Configuration:")
                print("- Sample buffer delegate set: \(self.videoOutput.sampleBufferDelegate != nil)")
                print("- Delegate queue label: \(self.videoOutputQueue.label)")
                
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                    if let connection = self.videoOutput.connection(with: .video) {
                        print("🔌 Video connection status:")
                        print("- Enabled: \(connection.isEnabled)")
                        print("- Active: \(connection.isActive)")
                        print("- Video orientation supported: \(connection.isVideoOrientationSupported)")
                        
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
                            print("✅ Set video orientation to portrait")
                        }
                        
                        if connection.isVideoStabilizationSupported {
                            connection.preferredVideoStabilizationMode = .auto
                            print("✅ Enabled video stabilization")
                        }
                        
                        if connection.isVideoMirroringSupported {
                            connection.isVideoMirrored = false
                            print("✅ Disabled video mirroring")
                        }
                    }
                }
                
                // Set session preset after configuring inputs and outputs
                if self.session.canSetSessionPreset(.hd4K) {
                    self.session.sessionPreset = .hd4K
                    print("✅ Set session preset to 4K")
                }
                
                self.session.commitConfiguration()
                print("✅ Session configuration committed")
                
                // Start the session immediately
                if !self.session.isRunning {
                    self.session.startRunning()
                    print("✅ Session started running")
                    
                    // Update UI on main thread
                    DispatchQueue.main.async {
                        self.isSessionRunning = true
                    }
                }
            } catch {
                print("❌ Error configuring session: \(error.localizedDescription)")
            }
        }
    }
    
    func startSession() {
        print("🎬 Starting capture session")
        
        // Check if already running on main thread
        if session.isRunning {
            print("ℹ️ Session already running")
            return
        }
        
        // Start session on background thread
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
                print("✅ Session started running")
            }
        }
    }
    
    func stopSession() {
        print("⏹ Stopping capture session")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
                print("✅ Session stopped running")
            }
        }
    }
} 