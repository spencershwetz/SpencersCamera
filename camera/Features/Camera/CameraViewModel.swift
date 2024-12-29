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
    @Published var shutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 60) // 1/60
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
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var currentRecordingURL: URL?
    
    private let videoOutputQueue = DispatchQueue(label: "com.camera.videoOutput")
    private let audioOutputQueue = DispatchQueue(label: "com.camera.audioOutput")
    
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
                      let connection = self.videoOutput?.connection(with: .video) else { return }
                self.updateVideoOrientation(connection)
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
                if let videoConnection = videoOutput?.connection(with: .video) {
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
                if let videoConnection = videoOutput?.connection(with: .video) {
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
        // Disable automatic wide color configuration
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        
        session.beginConfiguration()
        
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                        for: .video,
                                                        position: .back)
        else {
            error = .cameraUnavailable
            status = .failed
            session.commitConfiguration()
            return
        }
        self.device = videoDevice
        
        do {
            // If Apple Log is enabled, attempt best Apple Log 4K format
            if isAppleLogEnabled, let appleLogFormat = findBestAppleLogFormat(videoDevice) {
                let frameRateRange = appleLogFormat.videoSupportedFrameRateRanges.first!
                try videoDevice.lockForConfiguration()
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.maxFrameRate))
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.minFrameRate))
                videoDevice.activeFormat = appleLogFormat
                videoDevice.activeColorSpace = .appleLog
                videoDevice.unlockForConfiguration()
                print("Initial setup: Enabled Apple Log in 4K ProRes format")
            }
            
            // Add camera input
            let vidInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(vidInput) {
                session.addInput(vidInput)
            }
            
            // Video output
            videoOutput = AVCaptureVideoDataOutput()
            videoOutput?.setSampleBufferDelegate(self, queue: videoOutputQueue)
            videoOutput?.alwaysDiscardsLateVideoFrames = false
            if let vOut = videoOutput, session.canAddOutput(vOut) {
                session.addOutput(vOut)
                // Preview only; actual recording in Apple Log/ProRes
                vOut.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
                // Set initial orientation
                if let videoConnection = videoOutput?.connection(with: .video) {
                    updateVideoOrientation(videoConnection)
                }
            }
            
            // Audio output
            audioOutput = AVCaptureAudioDataOutput()
            audioOutput?.setSampleBufferDelegate(self, queue: audioOutputQueue)
            if let aOut = audioOutput, session.canAddOutput(aOut) {
                session.addOutput(aOut)
            }
            
            // After setting up video input, set initial frame rate
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
        
        // Add quality preset configuration
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
                self?.status = .running  // Set status when session starts
            }
        }
        
        // Check and store Apple Log support
        isAppleLogSupported = device?.formats.contains { format in
            format.supportedColorSpaces.contains(.appleLog)
        } ?? false
        
        // Store default format
        if let device = device {
            defaultFormat = device.activeFormat
        }
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
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: speed, iso: device.iso) { _ in }
            device.unlockForConfiguration()
            shutterSpeed = speed
        } catch {
            print("Shutter speed error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    // Start recording in ProRes422 at 4K with Apple Log if format allows
    func startRecording() {
        guard !isRecording && !isProcessingRecording else {
            print("Cannot start recording: Already in progress or processing")
            return
        }
        
        let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let vidFile = docPath.appendingPathComponent("recording-\(Date().timeIntervalSince1970).mov")
        currentRecordingURL = vidFile
        
        do {
            assetWriter = try AVAssetWriter(url: vidFile, fileType: .mov)
            
            // Set dimensions based on current interface orientation
            let isPortrait = currentInterfaceOrientation.isPortrait
            var videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.proRes422,
                AVVideoWidthKey: isPortrait ? 2160 : 3840,
                AVVideoHeightKey: isPortrait ? 3840 : 2160
            ]
            
            if isAppleLogEnabled {
                videoSettings[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                ]
            }
            
            if let fmt = device?.activeFormat {
                videoInput = AVAssetWriterInput(mediaType: .video,
                                          outputSettings: videoSettings,
                                          sourceFormatHint: fmt.formatDescription)
                
                // Add these optimizations
                videoInput?.performsMultiPassEncodingIfSupported = true
                videoInput?.expectsMediaDataInRealTime = true
                
                // Add a pixel buffer adaptor for better performance
                let attributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferWidthKey as String: isPortrait ? 2160 : 3840,
                    kCVPixelBufferHeightKey as String: isPortrait ? 3840 : 2160
                ]
                
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: videoInput!,
                    sourcePixelBufferAttributes: attributes
                )
                
                if assetWriter?.canAdd(videoInput!) == true {
                    assetWriter?.add(videoInput!)
                }
            }
            
            // Audio
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, // Use uncompressed audio
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true
            
            if let aIn = audioInput, assetWriter?.canAdd(aIn) == true {
                assetWriter?.add(aIn)
            }
            
            isRecording = true
            print("Starting recording to: \(vidFile)")
        } catch {
            print("Failed to create asset writer: \(error)")
            self.error = .recordingFailed
        }
    }
    
    func stopRecording() {
        guard isRecording else {
            print("Cannot stop recording: No ongoing recording")
            return
        }
        
        print("Stopping recording...")
        isProcessingRecording = true
        isRecording = false
        
        guard let writer = assetWriter,
              writer.status == .writing else {
            print("❌ Cannot stop recording: Asset writer status is \(assetWriter?.status.rawValue ?? -1)")
            isProcessingRecording = false
            error = .recordingFailed
            return
        }
        
        let finishGroup = DispatchGroup()
        
        if let vIn = videoInput {
            finishGroup.enter()
            videoOutputQueue.async {
                vIn.markAsFinished()
                finishGroup.leave()
            }
        }
        if let aIn = audioInput {
            finishGroup.enter()
            audioOutputQueue.async {
                aIn.markAsFinished()
                finishGroup.leave()
            }
        }
        
        finishGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            print("Finishing asset writer...")
            
            writer.finishWriting { [weak self] in
                guard let self = self else { return }
                
                if let err = writer.error {
                    print("❌ Error finishing recording: \(err)")
                    DispatchQueue.main.async {
                        self.error = .recordingFailed
                        self.isProcessingRecording = false
                    }
                    return
                }
                
                if let outURL = self.currentRecordingURL {
                    print("✅ Recording finished successfully")
                    self.saveVideoToPhotoLibrary(outURL)
                } else {
                    print("❌ No output URL available")
                    DispatchQueue.main.async {
                        self.error = .recordingFailed
                        self.isProcessingRecording = false
                    }
                }
            }
        }
    }
    
    private func saveVideoToPhotoLibrary(_ url: URL) {
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    self?.error = .savingFailed
                    self?.isProcessingRecording = false
                    print("Photo library access denied")
                }
                return
            }
            
            PHPhotoLibrary.shared().performChanges {
                let opts = PHAssetResourceCreationOptions()
                opts.shouldMoveFile = true
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .video, fileURL: url, options: opts)
            } completionHandler: { success, error in
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
    
    private func updateVideoOrientation(_ connection: AVCaptureConnection) {
        guard connection.isVideoOrientationSupported else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let interfaceOrientation = windowScene.interfaceOrientation
                self.currentInterfaceOrientation = interfaceOrientation
                
                switch interfaceOrientation {
                case .portrait:
                    connection.videoOrientation = .portrait
                case .portraitUpsideDown:
                    connection.videoOrientation = .portraitUpsideDown
                case .landscapeLeft:
                    connection.videoOrientation = .landscapeRight
                case .landscapeRight:
                    connection.videoOrientation = .landscapeLeft
                default:
                    connection.videoOrientation = .portrait
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
            if device.activeFormat.isVideoStabilizationSupported {
                if let connection = videoOutput?.connection(with: .video),
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
}

// MARK: - Sample Buffer Delegate
extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        // Monitor frame rate less frequently
        if output is AVCaptureVideoDataOutput {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            if let lastTime = lastFrameTime {
                let delta = CMTimeGetSeconds(CMTimeSubtract(timestamp, lastTime))
                let instantFPS = 1.0 / delta
                
                frameRateAccumulator += instantFPS
                frameCount += 1
                
                // Increase interval for frame rate checks
                if frameCount >= 60 { // Check every 60 frames instead of 30
                    let averageFPS = frameRateAccumulator / Double(frameCount)
                    print("Current frame rate: \(String(format: "%.3f", averageFPS)) fps")
                    
                    // Only log significant deviations
                    if abs(averageFPS - selectedFrameRate) > 0.5 {
                        print("⚠️ Frame rate deviation detected: \(String(format: "%.3f", averageFPS)) fps vs target \(selectedFrameRate) fps")
                        adjustFrameRatePrecision(currentFPS: averageFPS)
                    }
                    
                    frameCount = 0
                    frameRateAccumulator = 0
                }
            }
            lastFrameTime = timestamp
        }
        
        // Handle recording
        guard isRecording,
              let writer = assetWriter else { return }
        
        let isVideo = (output is AVCaptureVideoDataOutput)
        let writerInput = isVideo ? videoInput : audioInput
        
        // Process on high-priority background queue
        processingQueue.async {
            switch writer.status {
            case .unknown:
                if isVideo {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    writer.startWriting()
                    writer.startSession(atSourceTime: pts)
                    
                    if let wI = writerInput, wI.isReadyForMoreMediaData {
                        wI.append(sampleBuffer)
                    }
                }
            case .writing:
                if let wI = writerInput, wI.isReadyForMoreMediaData {
                    wI.append(sampleBuffer)
                }
            case .failed:
                print("❌ Asset writer failed: \(writer.error?.localizedDescription ?? "unknown error")")
                DispatchQueue.main.async {
                    self.error = .recordingFailed
                    self.isRecording = false
                    self.isProcessingRecording = false
                }
            default:
                break
            }
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let isVideo = (output is AVCaptureVideoDataOutput)
        print("Dropped \(isVideo ? "video" : "audio") buffer")
    }
}

// MARK: - Orientation Helper
private extension UIDeviceOrientation {
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
