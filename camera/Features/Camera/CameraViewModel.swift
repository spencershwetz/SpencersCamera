import AVFoundation
import SwiftUI
import Photos
import VideoToolbox
import CoreVideo
import os.log

class CameraViewModel: NSObject, ObservableObject {
    enum Status {
        case unknown
        case running
        case failed
        case unauthorized
    }
    @Published private(set) var status: Status = .unknown
    
    enum CaptureMode {
        case photo
        case video
    }
    @Published var captureMode: CaptureMode = .video
    
    private let logger = Logger(subsystem: "com.camera", category: "CameraViewModel")
    
    @Published var isSessionRunning = false
    @Published var error: CameraError?
    @Published var whiteBalance: Float = 5000 // Kelvin
    @Published var iso: Float = 100
    @Published var shutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 60) // Initialize for 180° at 30fps
    @Published var isRecording = false
    @Published var recordingFinished = false
    @Published var isSettingsPresented = false
    @Published var isProcessingRecording = false
    
    // Enable Apple Log (4K ProRes) by default if device supports it
    @Published var isAppleLogEnabled = false {
        didSet {
            print("\n=== Apple Log Toggle ===")
            print("🔄 Status: \(status)")
            print("📹 Capture Mode: \(captureMode)")
            print("✅ Attempting to set Apple Log to: \(isAppleLogEnabled)")
            
            guard status == .running, captureMode == .video else {
                print("❌ Cannot configure Apple Log - Status or mode incorrect")
                print("Required: status == .running (is: \(status))")
                print("Required: captureMode == .video (is: \(captureMode))")
                return
            }
            
            // Use Task with proper error handling
            Task {
                do {
                    if isAppleLogEnabled {
                        print("🎥 Configuring Apple Log...")
                        try await configureAppleLog()
                    } else {
                        print("↩️ Resetting Apple Log...")
                        try await resetAppleLog()
                    }
                } catch {
                    await MainActor.run {
                        self.error = .configurationFailed
                    }
                    logger.error("Failed to configure Apple Log: \(error.localizedDescription)")
                    print("❌ Apple Log configuration failed: \(error)")
                }
            }
            print("=== End Apple Log Toggle ===\n")
        }
    }
    
    @Published private(set) var isAppleLogSupported = false
    
    let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    
    // Add movie file output
    private let movieOutput = AVCaptureMovieFileOutput()
    private var currentRecordingURL: URL?
    
    private var defaultFormat: AVCaptureDevice.Format?
    
    var minISO: Float {
        device?.activeFormat.minISO ?? 50
    }
    var maxISO: Float {
        device?.activeFormat.maxISO ?? 1600
    }
    
    // Add new property for frame rate
    @Published var selectedFrameRate: Double = 30.0
    
    // Add available frame rates
    let availableFrameRates: [Double] = [23.976, 24.0, 25.0, 29.97, 30.0]
    
    private var orientationObserver: NSObjectProtocol?
    
    // Add property to track interface orientation
    @Published private(set) var currentInterfaceOrientation: UIInterfaceOrientation = .portrait
    
    private let processingQueue = DispatchQueue(
        label: "com.camera.processing",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    
    // Add properties for frame rate monitoring
    private var lastFrameTimestamp: CFAbsoluteTime = 0
    
    private var lastFrameTime: CMTime?
    private var frameCount: Int = 0
    private var frameRateAccumulator: Double = 0
    private var frameRateUpdateInterval: Int = 30 // Update every 30 frames
    
    // Add property to store supported frame rate range
    private var supportedFrameRateRange: AVFrameRateRange? {
        device?.activeFormat.videoSupportedFrameRateRanges.first
    }
    
    // Add properties for advanced configuration
    private var videoConfiguration: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.proRes422,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 50_000_000, // 50 Mbps
            AVVideoMaxKeyFrameIntervalKey: 1, // Every frame is keyframe
            AVVideoAllowFrameReorderingKey: false,
            AVVideoExpectedSourceFrameRateKey: 30
        ]
    ]
    
    // Add these constants
    private struct FrameRates {
        static let ntsc23_976 = CMTime(value: 1001, timescale: 24000)  // 23.976 fps
        static let ntsc29_97 = CMTime(value: 1001, timescale: 30000)   // 29.97 fps
        static let film24 = CMTime(value: 1, timescale: 24)            // 24 fps
        static let pal25 = CMTime(value: 1, timescale: 25)             // 25 fps
        static let ntsc30 = CMTime(value: 1, timescale: 30)            // 30 fps
    }
    
    @Published var currentTint: Double = 0.0 // Range: -150 to +150
    private let tintRange = (-150.0...150.0)
    
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    override init() {
        super.init()
        print("\n=== Camera Initialization ===")
        
        do {
            try setupSession()
            
            // Print device capabilities
            if let device = device {
                print("📊 Device Capabilities:")
                print("- Name: \(device.localizedName)")
                print("- Model ID: \(device.modelID)")
                
                print("\n🎨 Supported Color Spaces:")
                device.formats.forEach { format in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let codecType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                    print("""
                        Format: \(dimensions.width)x\(dimensions.height) - Codec: \(codecType)
                        - Color Spaces: \(format.supportedColorSpaces.map { $0.rawValue })
                        - Supports Apple Log: \(format.supportedColorSpaces.contains(.appleLog))
                        - Supports HDR: \(format.isVideoHDRSupported)
                        """)
                }
                
                isAppleLogSupported = device.formats.contains { format in
                    format.supportedColorSpaces.contains(.appleLog)
                }
                print("\n✅ Apple Log Support: \(isAppleLogSupported)")
            }
            print("=== End Initialization ===\n")
            
            // Store default format
            if let device = device {
                defaultFormat = device.activeFormat
            }
            
            // Check Apple Log support
            isAppleLogSupported = device?.formats.contains { format in
                format.supportedColorSpaces.contains(.appleLog)
            } ?? false
        } catch {
            self.error = .setupFailed
            print("Failed to setup session: \(error)")
        }
        
        // Add orientation observer
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                guard let self = self,
                      let connection = self.movieOutput.connection(with: .video) else { return }
                self.updateVideoOrientation(connection)
        }
        
        // After other initialization, set initial shutter angle to 180°
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateShutterAngle(180.0) // Set initial shutter angle to 180°
        }
    }
    
    deinit {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    /// Returns a 4K (3840x2160) AppleProRes422 format that also supports Apple Log
    private func findBestAppleLogFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        return device.formats.first { format in
            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            let codecType = CMFormatDescriptionGetMediaSubType(desc)
            
            let is4K = (dimensions.width == 3840 && dimensions.height == 2160)
            let isProRes422 = (codecType == kCMVideoCodecType_AppleProRes422) // 'x422'
            let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
            
            return is4K && isProRes422 && hasAppleLog
        }
    }
    
    private func configureAppleLog() async throws {
        guard let device = device else {
            print("❌ No camera device available")
            return
        }
        
        print("\n=== Apple Log Configuration ===")
        print("🎥 Current device: \(device.localizedName)")
        print("📊 Current format: \(device.activeFormat.formatDescription)")
        print("🎨 Current color space: \(device.activeColorSpace.rawValue)")
        print("🎨 Wide color enabled: \(session.automaticallyConfiguresCaptureDeviceForWideColor)")
        
        // Ensure wide color is disabled
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        
        // Check if format supports Apple Log
        let supportsAppleLog = device.formats.contains { format in
            format.supportedColorSpaces.contains(.appleLog)
        }
        print("✓ Device supports Apple Log: \(supportsAppleLog)")
        
        do {
            session.stopRunning()
            print("⏸️ Session stopped for reconfiguration")
            
            try await Task.sleep(for: .milliseconds(100))
            session.beginConfiguration()
            
            try device.lockForConfiguration()
            defer {
                device.unlockForConfiguration()
                session.commitConfiguration()
                
                // Fix orientation after configuration
                if let videoConnection = movieOutput.connection(with: .video) {
                    updateVideoOrientation(videoConnection)
                }
                
                session.startRunning()
            }
            
            // Find best Apple Log format
            if let format = device.formats.first(where: {
                let desc = $0.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                let codecType = CMFormatDescriptionGetMediaSubType(desc)
                
                let is4K = (dimensions.width == 3840 && dimensions.height == 2160)
                // Check for ProRes422 or ProRes422HQ codec
                let isProRes = (codecType == kCMVideoCodecType_AppleProRes422 ||
                              codecType == kCMVideoCodecType_AppleProRes422HQ ||
                              codecType == 2016686642) // This is the codec we see in the logs
                let hasAppleLog = $0.supportedColorSpaces.contains(.appleLog)
                
                print("""
                    Checking format:
                    - Resolution: \(dimensions.width)x\(dimensions.height) (is4K: \(is4K))
                    - Codec: \(codecType) (isProRes: \(isProRes))
                    - Has Apple Log: \(hasAppleLog)
                    """)
                
                return (is4K || dimensions.width >= 1920) && isProRes && hasAppleLog
            }) {
                print("✅ Found suitable Apple Log format")
                print("📹 Format details: \(format.formatDescription)")
                
                // Remove this part that was resetting frame rate
                // let frameRateRange = format.videoSupportedFrameRateRanges.first!
                // device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.maxFrameRate))
                // device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.minFrameRate))
                
                // Instead, maintain current frame rate
                let duration = CMTimeMake(value: 1000, timescale: Int32(selectedFrameRate * 1000))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                
                // Set format and color space
                device.activeFormat = format
                device.activeColorSpace = .appleLog
                print("🎨 Set color space to Apple Log")
                
                print("✅ Successfully configured Apple Log format")
            } else {
                print("❌ No suitable Apple Log format found")
                throw CameraError.configurationFailed
            }
            
            print("💾 Configuration committed")
            print("▶️ Session restarted")
            
        } catch {
            print("❌ Error configuring Apple Log: \(error.localizedDescription)")
            
            // Ensure we properly clean up on error
            device.unlockForConfiguration()
            session.commitConfiguration()
            session.startRunning()
            
            // Update UI on main thread
            await MainActor.run {
                self.error = .configurationFailed
            }
            
            print("🔄 Attempting session recovery")
            throw error
        }
        
        print("=== End Apple Log Configuration ===\n")
    }
    
    private func resetAppleLog() async throws {
        guard let device = device else {
            print("❌ No camera device available")
            return
        }
        
        print("\n=== Resetting Apple Log Configuration ===")
        print("🎨 Wide color enabled: \(session.automaticallyConfiguresCaptureDeviceForWideColor)")
        
        // Ensure wide color is disabled
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        
        do {
            session.stopRunning()
            session.beginConfiguration()
            
            try device.lockForConfiguration()
            defer {
                device.unlockForConfiguration()
                session.commitConfiguration()
                
                // Fix orientation after configuration
                if let videoConnection = movieOutput.connection(with: .video) {
                    updateVideoOrientation(videoConnection)
                }
                
                session.startRunning()
            }
            
            if let defaultFormat = defaultFormat {
                device.activeFormat = defaultFormat
            }
            device.activeColorSpace = .sRGB
            
            session.commitConfiguration()
            session.startRunning()
            
            print("✅ Successfully reset to sRGB color space")
        } catch {
            print("❌ Error resetting Apple Log: \(error.localizedDescription)")
            self.error = .configurationFailed
            session.startRunning()
        }
        
        print("=== End Reset ===\n")
    }
    
    private func setupSession() throws {
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.beginConfiguration()
        
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .back) else {
            error = .cameraUnavailable
            status = .failed
            session.commitConfiguration()
            return
        }
        
        self.device = videoDevice
        
        do {
            // Initialize videoDeviceInput
            let input = try AVCaptureDeviceInput(device: videoDevice)
            self.videoDeviceInput = input
            
            // Configure Apple Log if enabled
            if isAppleLogEnabled, let appleLogFormat = findBestAppleLogFormat(videoDevice) {
                let frameRateRange = appleLogFormat.videoSupportedFrameRateRanges.first!
                try videoDevice.lockForConfiguration()
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.maxFrameRate))
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.minFrameRate))
                videoDevice.activeFormat = appleLogFormat
                videoDevice.activeColorSpace = .appleLog
                print("Initial setup: Enabled Apple Log in 4K ProRes format")
            }
            
            // Add video input
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            // Add audio input
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
            }
            
            // Configure movie output
            if session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
                
                // Configure for high quality
                movieOutput.movieFragmentInterval = .invalid
                
                if let connection = movieOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }
                    updateVideoOrientation(connection)
                }
            }
            
            // Set initial frame rate
            if let device = device {
                try device.lockForConfiguration()
                let duration = CMTimeMake(value: 1000, timescale: Int32(selectedFrameRate * 1000))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            }
            
        } catch {
            print("Error setting up camera: \(error)")
            self.error = .setupFailed
            session.commitConfiguration()
            return
        }
        
        session.commitConfiguration()
        
        // Configure session preset
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }
        
        // Start session
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = self?.session.isRunning ?? false
                self?.status = .running
            }
        }
        
        // Check Apple Log support
        isAppleLogSupported = device?.formats.contains { format in
            format.supportedColorSpaces.contains(.appleLog)
        } ?? false
        
        // Store default format
        defaultFormat = device?.activeFormat
    }
    
    // White Balance
    func updateWhiteBalance(_ temperature: Float) {
        guard let device = device else { return }
        do {
            try device.lockForConfiguration()
            let tnt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0.0)
            var gains = device.deviceWhiteBalanceGains(for: tnt)
            let maxGain = device.maxWhiteBalanceGain
            
            gains.redGain   = min(max(1.0, gains.redGain), maxGain)
            gains.greenGain = min(max(1.0, gains.greenGain), maxGain)
            gains.blueGain  = min(max(1.0, gains.blueGain), maxGain)
            
            device.setWhiteBalanceModeLocked(with: gains) { _ in }
            device.unlockForConfiguration()
            
            whiteBalance = temperature
        } catch {
            print("White balance error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    // ISO
    func updateISO(_ iso: Float) {
        guard let device = device else { return }
        do {
            try device.lockForConfiguration()
            let clamped = min(max(device.activeFormat.minISO, iso), device.activeFormat.maxISO)
            device.setExposureModeCustom(duration: device.exposureDuration, iso: clamped) { _ in }
            device.unlockForConfiguration()
            self.iso = clamped
        } catch {
            print("ISO error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    // Shutter
    func updateShutterSpeed(_ speed: CMTime) {
        guard let device = device else { return }
        do {
            print("\n⚡ Updating Shutter Speed:")
            print("  - Input Time: \(speed.value)/\(speed.timescale)")
            print("  - Duration: \(speed.seconds) seconds")
            
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: speed, iso: device.iso) { _ in }
            device.unlockForConfiguration()
            
            // Update the published property on the main thread
            DispatchQueue.main.async {
                self.shutterSpeed = speed
                
                // Calculate and log the resulting angle
                let resultingAngle = Double(speed.value) / Double(speed.timescale) * self.selectedFrameRate * 360.0
                print("  - Resulting Angle: \(resultingAngle)°")
            }
        } catch {
            print("❌ Shutter speed error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    // Start recording in ProRes422 at 4K with Apple Log if format allows
    func startRecording() {
        guard !isRecording && !isProcessingRecording else {
            print("Cannot start recording: Already in progress or processing")
            return
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoName = "recording-\(Date().timeIntervalSince1970).mov"
        let videoPath = documentsPath.appendingPathComponent(videoName)
        currentRecordingURL = videoPath
        
        // Start recording
        movieOutput.startRecording(to: videoPath, recordingDelegate: self)
        isRecording = true
        print("Starting recording to: \(videoPath.path)")
    }
    
    func stopRecording() {
        guard isRecording else {
            print("Cannot stop recording: No ongoing recording")
            return
        }
        
        print("Stopping recording...")
        isProcessingRecording = true
        movieOutput.stopRecording()
    }
    
    private func updateVideoOrientation(_ connection: AVCaptureConnection) {
        // Check if rotation is supported for our required angles
        let requiredAngles: [CGFloat] = [0, 90, 180, 270]
        let supportsRotation = requiredAngles.allSatisfy { angle in
            connection.isVideoRotationAngleSupported(angle)
        }
        
        guard supportsRotation else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let interfaceOrientation = windowScene.interfaceOrientation
                self.currentInterfaceOrientation = interfaceOrientation
                
                // Adjusted angles to fix upside down horizontal video
                switch interfaceOrientation {
                case .portrait:
                    connection.videoRotationAngle = 90   // Keep portrait the same
                case .portraitUpsideDown:
                    connection.videoRotationAngle = 270  // Keep upside down portrait the same
                case .landscapeLeft:
                    connection.videoRotationAngle = 180  // Changed from 0 to 180
                case .landscapeRight:
                    connection.videoRotationAngle = 0    // Changed from 180 to 0
                default:
                    connection.videoRotationAngle = 90   // Keep default the same
                }
            }
            
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = false
            }
        }
    }
    
    // Add new method to find compatible format for frame rate
    private func findCompatibleFormat(for fps: Double) -> AVCaptureDevice.Format? {
        guard let device = device else { return nil }
        
        print("\n=== Checking Format Compatibility ===")
        print("Requested frame rate: \(fps) fps")
        
        let formats = device.formats.filter { format in
            // Get current dimensions
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let isHighRes = dimensions.width >= 1920 // At least 1080p
            
            // Check frame rate support
            let supportsFrameRate = format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= fps && fps <= range.maxFrameRate
            }
            
            // For Apple Log, ensure format supports it
            if isAppleLogEnabled {
                return isHighRes && supportsFrameRate && format.supportedColorSpaces.contains(.appleLog)
            }
            
            return isHighRes && supportsFrameRate
        }
        
        // Log available formats
        formats.forEach { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges
            print("""
                Format: \(dims.width)x\(dims.height)
                - Frame rates: \(ranges.map { "\($0.minFrameRate)-\($0.maxFrameRate)" }.joined(separator: ", "))
                - Supports Apple Log: \(format.supportedColorSpaces.contains(.appleLog))
                """)
        }
        
        return formats.first
    }
    
    // Update frame rate setting method
    func updateFrameRate(_ fps: Double) {
        guard let device = device else { return }
        
        do {
            // Find compatible format first
            guard let compatibleFormat = findCompatibleFormat(for: fps) else {
                print("❌ No compatible format found for \(fps) fps")
                return
            }
            
            try device.lockForConfiguration()
            
            // Set format if different from current
            if device.activeFormat != compatibleFormat {
                print("Switching to compatible format...")
                device.activeFormat = compatibleFormat
            }
            
            // Get precise frame duration
            let frameDuration: CMTime
            switch fps {
            case 23.976:
                frameDuration = FrameRates.ntsc23_976
            case 29.97:
                frameDuration = FrameRates.ntsc29_97
            case 24:
                frameDuration = FrameRates.film24
            case 25:
                frameDuration = FrameRates.pal25
            case 30:
                frameDuration = FrameRates.ntsc30
            default:
                frameDuration = CMTimeMake(value: 1, timescale: Int32(fps))
            }
            
            // Set both min and max to the same duration for precise timing
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            
            // Update state on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.selectedFrameRate = fps
                self.frameCount = 0
                self.frameRateAccumulator = 0
                self.lastFrameTime = nil
            }
            
            print("""
                ✅ Frame rate configured:
                - Rate: \(fps) fps
                - Duration: \(frameDuration.seconds) seconds
                - Format: \(CMVideoFormatDescriptionGetDimensions(compatibleFormat.formatDescription))
                """)
            
            device.unlockForConfiguration()
        } catch {
            print("❌ Frame rate error: \(error)")
            self.error = .configurationFailed
        }
        
        // Store current shutter angle before changing frame rate
        let currentAngle = shutterAngle
        
        // After frame rate is updated, restore the shutter angle
        updateShutterAngle(currentAngle)
    }
    
    // Update frame rate monitoring to be less aggressive and use main thread
    private func adjustFrameRatePrecision(currentFPS: Double) {
        // Only adjust if deviation is significant (more than 2%)
        let deviation = abs(currentFPS - selectedFrameRate) / selectedFrameRate
        guard deviation > 0.02 else { return }
        
        // Add delay between adjustments
        let now = Date().timeIntervalSince1970
        guard (now - lastAdjustmentTime) > 1.0 else { return } // Wait at least 1 second between adjustments
        
        lastAdjustmentTime = now
        
        // Reset frame rate to selected value instead of trying to adjust
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateFrameRate(self.selectedFrameRate)
        }
    }
    
    // Add property to track last adjustment time
    private var lastAdjustmentTime: TimeInterval = 0
    
    // Add method to update orientation
    func updateInterfaceOrientation() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                self.currentInterfaceOrientation = windowScene.interfaceOrientation
            }
        }
    }
    
    // Add HDR support
    private func configureHDR() {
        guard let device = device,
              device.activeFormat.isVideoHDRSupported else { return }
        
        do {
            try device.lockForConfiguration()
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = true
            device.unlockForConfiguration()
        } catch {
            print("Error configuring HDR: \(error)")
        }
    }
    
    private func optimizeVideoCapture() {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            
            // Stabilization
            if device.activeFormat.isVideoStabilizationModeSupported(.cinematic) {
                if let connection = movieOutput.connection(with: .video),
                   connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .cinematic
                }
            }
            
            // Auto focus system
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            
            // Auto exposure
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            
            // White balance
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            device.unlockForConfiguration()
        } catch {
            print("Error optimizing video capture: \(error)")
        }
    }
    
    private func configureTintSettings() {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
                
                // Get current white balance gains
                let currentGains = device.deviceWhiteBalanceGains
                var newGains = currentGains
                
                // Calculate tint scale factor (-1.0 to 1.0)
                let tintScale = currentTint / 150.0 // Normalize to -1.0 to 1.0
                
                if tintScale > 0 {
                    // Green tint: increase green gain
                    newGains.greenGain = currentGains.greenGain * (1.0 + Float(tintScale))
                } else {
                    // Magenta tint: increase red and blue gains
                    let magentaScale = 1.0 + Float(abs(tintScale))
                    newGains.redGain = currentGains.redGain * magentaScale
                    newGains.blueGain = currentGains.blueGain * magentaScale
                }
                
                // Clamp gains to valid range
                let maxGain = device.maxWhiteBalanceGain
                newGains.redGain = min(max(1.0, newGains.redGain), maxGain)
                newGains.greenGain = min(max(1.0, newGains.greenGain), maxGain)
                newGains.blueGain = min(max(1.0, newGains.blueGain), maxGain)
                
                // Set the white balance gains
                device.setWhiteBalanceModeLocked(with: newGains) { _ in }
            }
            device.unlockForConfiguration()
        } catch {
            print("Error setting tint: \(error.localizedDescription)")
            self.error = .whiteBalanceError
        }
    }
    
    // Add this function to be called when tint slider changes
    func updateTint(_ newValue: Double) {
        currentTint = newValue.clamped(to: tintRange)
        configureTintSettings()
    }
    
    // Convert shutter speed to angle
    var shutterAngle: Double {
        get {
            // Calculate the actual angle from the current shutter speed and frame rate
            let angle = Double(shutterSpeed.value) / Double(shutterSpeed.timescale) * selectedFrameRate * 360.0
            let clampedAngle = min(max(angle, 1.1), 360.0)
            
            print("📐 Getting Shutter Angle:")
            print("  - Raw Angle: \(angle)°")
            print("  - Clamped Angle: \(clampedAngle)°")
            print("  - Current FPS: \(selectedFrameRate)")
            print("  - Shutter Speed: 1/\(1.0/shutterSpeed.seconds)")
            
            return clampedAngle
        }
        set {
            let clampedAngle = min(max(newValue, 1.1), 360.0)
            
            // Calculate the exact shutter duration needed for this angle
            // duration = (angle/360) * (1/fps)
            let duration = (clampedAngle/360.0) * (1.0/selectedFrameRate)
            
            print("🔄 Setting Shutter Angle:")
            print("  - Requested Angle: \(newValue)°")
            print("  - Clamped Angle: \(clampedAngle)°")
            print("  - Calculated Duration: \(duration)")
            
            let time = CMTimeMakeWithSeconds(duration, preferredTimescale: 1000000)
            
            // Update the camera settings first
            updateShutterSpeed(time)
            
            // Then update our stored value
            DispatchQueue.main.async {
                self.shutterSpeed = time
            }
        }
    }
    
    // Update method to handle angle directly
    func updateShutterAngle(_ angle: Double) {
        print("\n🎯 Updating Shutter Angle:")
        print("  - Requested Angle: \(angle)°")
        
        // Set the shutter angle through the property
        self.shutterAngle = angle
    }
}

// MARK: - Sample Buffer Delegate
extension CameraViewModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                   didStartRecordingTo fileURL: URL,
                   from connections: [AVCaptureConnection]) {
        print("Recording started successfully")
    }
    
    func fileOutput(_ output: AVCaptureFileOutput,
                   didFinishRecordingTo outputFileURL: URL,
                   from connections: [AVCaptureConnection],
                   error: Error?) {
        isRecording = false
        
        if let error = error {
            print("Recording failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.error = .recordingFailed
                self.isProcessingRecording = false
            }
            return
        }
        
        // Save to photo library
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    self?.error = .savingFailed
                    self?.isProcessingRecording = false
                    print("Photo library access denied")
                }
                return
            }
            
            PHPhotoLibrary.shared().performChanges({
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .video,
                                          fileURL: outputFileURL,
                                          options: options)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        print("Video saved to photo library")
                        self?.recordingFinished = true
                    } else {
                        print("Error saving video: \(String(describing: error))")
                        self?.error = .savingFailed
                    }
                    self?.isProcessingRecording = false
                }
            }
        }
    }
}

// MARK: - Orientation Helper
extension UIDeviceOrientation {
    var videoTransform: CGAffineTransform {
        switch self {
        case .landscapeRight:
            return CGAffineTransform(rotationAngle: CGFloat.pi)
        case .portraitUpsideDown:
            return CGAffineTransform(rotationAngle: -CGFloat.pi / 2)
        case .landscapeLeft:
            return .identity
        case .portrait:
            return CGAffineTransform(rotationAngle: CGFloat.pi / 2)
        case .unknown, .faceUp, .faceDown:
            return CGAffineTransform(rotationAngle: CGFloat.pi / 2)
        @unknown default:
            return CGAffineTransform(rotationAngle: CGFloat.pi / 2)
        }
    }
}

// Add extension to AVFrameRateRange
extension AVFrameRateRange {
    func containsFrameRate(_ fps: Double) -> Bool {
        return fps >= minFrameRate && fps <= maxFrameRate
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
