import AVFoundation
import SwiftUI
import Photos
import VideoToolbox
import CoreVideo
import os.log
import CoreImage
import CoreMedia

extension CFString {
    var string: String {
        self as String
    }
}

extension AVCaptureDevice.Format {
    var dimensions: CMVideoDimensions? {
        CMVideoFormatDescriptionGetDimensions(formatDescription)
    }
}

class CameraViewModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    // Add property to track the view containing the camera preview
    weak var owningView: UIView?
    
    // Flashlight manager
    private let flashlightManager = FlashlightManager()
    private var settingsObserver: NSObjectProtocol?
    
    enum Status {
        case unknown
        case running
        case failed
        case unauthorized
    }
    @Published var status: Status = .unknown
    
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
    @Published var shutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 60)
    @Published var isRecording = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)
            
            // Handle flashlight state based on recording state
            let settings = SettingsModel()
            if isRecording && settings.isFlashlightEnabled {
                Task {
                    await flashlightManager.performStartupSequence()
                }
            } else {
                flashlightManager.cleanup()
            }
        }
    }
    @Published var recordingFinished = false
    @Published var isSettingsPresented = false
    @Published var isProcessingRecording = false
    
    // Add thumbnail property
    @Published var lastRecordedVideoThumbnail: UIImage?
    
    // Storage for temporarily disabling LUT preview without losing the filter
    var tempLUTFilter: CIFilter? {
        didSet {
            if tempLUTFilter != nil {
                print("DEBUG: CameraViewModel stored LUT filter temporarily")
            } else if oldValue != nil {
                print("DEBUG: CameraViewModel cleared temporary LUT filter")
            }
        }
    }
    
    @Published var isAppleLogEnabled = true { // Set Apple Log enabled by default
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
    
    // Video recording properties
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var assetWriterPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var currentRecordingURL: URL?
    private var recordingStartTime: CMTime?
    
    private var defaultFormat: AVCaptureDevice.Format?
    
    var minISO: Float {
        device?.activeFormat.minISO ?? 50
    }
    var maxISO: Float {
        device?.activeFormat.maxISO ?? 1600
    }
    
    @Published var selectedFrameRate: Double = 30.0
    let availableFrameRates: [Double] = [23.976, 24.0, 25.0, 29.97, 30.0]
    
    private var orientationObserver: NSObjectProtocol?
    @Published private(set) var currentInterfaceOrientation: UIInterfaceOrientation = .portrait
    
    private let processingQueue = DispatchQueue(
        label: "com.camera.processing",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    
    private var lastFrameTimestamp: CFAbsoluteTime = 0
    private var lastFrameTime: CMTime?
    private var frameCount: Int = 0
    private var frameRateAccumulator: Double = 0
    private var frameRateUpdateInterval: Int = 30
    
    private var supportedFrameRateRange: AVFrameRateRange? {
        device?.activeFormat.videoSupportedFrameRateRanges.first
    }
    
    // Resolution settings
    enum Resolution: String, CaseIterable {
        case uhd = "4K (3840x2160)"
        case hd = "HD (1920x1080)"
        case sd = "720p (1280x720)"
        
        var dimensions: CMVideoDimensions {
            switch self {
            case .uhd: return CMVideoDimensions(width: 3840, height: 2160)
            case .hd: return CMVideoDimensions(width: 1920, height: 1080)
            case .sd: return CMVideoDimensions(width: 1280, height: 720)
            }
        }
    }
    
    @Published var selectedResolution: Resolution = .uhd {
        didSet {
            Task {
                do {
                    try await updateCameraFormat(for: selectedResolution)
                } catch {
                    print("Error updating camera format: \(error)")
                    self.error = .configurationFailed
                }
            }
        }
    }
    
    // Codec settings
    enum VideoCodec: String, CaseIterable {
        case hevc = "HEVC (H.265)"
        case proRes = "Apple ProRes"
        
        var avCodecKey: AVVideoCodecType {
            switch self {
            case .hevc: return .hevc
            case .proRes: return .proRes422HQ
            }
        }
        
        var bitrate: Int {
            switch self {
            case .hevc: return 50_000_000 // Increased to 50 Mbps for 4:2:2
            case .proRes: return 0 // ProRes doesn't use bitrate control
            }
        }
    }
    
    @Published var selectedCodec: VideoCodec = .hevc { // Set HEVC as default codec
        didSet {
            updateVideoConfiguration()
        }
    }
    
    private var videoConfiguration: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.proRes422,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 50_000_000,
            AVVideoMaxKeyFrameIntervalKey: 1,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoExpectedSourceFrameRateKey: 30
        ]
    ]
    
    private struct FrameRates {
        static let ntsc23_976 = CMTime(value: 1001, timescale: 24000)
        static let ntsc29_97 = CMTime(value: 1001, timescale: 30000)
        static let film24 = CMTime(value: 1, timescale: 24)
        static let pal25 = CMTime(value: 1, timescale: 25)
        static let ntsc30 = CMTime(value: 1, timescale: 30)
    }
    
    @Published var currentTint: Double = 0.0 // Range: -150 to +150
    private let tintRange = (-150.0...150.0)
    
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    @Published var isAutoExposureEnabled: Bool = true {
        didSet {
            updateExposureMode()
        }
    }
    
    @Published var lutManager = LUTManager()
    private var ciContext = CIContext()
    
    // Add flag to lock orientation updates during recording
    private var recordingOrientationLocked = false
    
    // Save the original rotation values to restore them after recording
    private var originalRotationValues: [AVCaptureConnection: CGFloat] = [:]
    
    @Published var currentLens: CameraLens = .wide
    @Published var availableLenses: [CameraLens] = []
    
    @Published var currentZoomFactor: CGFloat = 1.0
    private var lastZoomFactor: CGFloat = 1.0
    
    // HEVC Hardware Encoding Properties
    private var compressionSession: VTCompressionSession?
    private let encoderQueue = DispatchQueue(label: "com.camera.encoder", qos: .userInteractive)
    
    // Add constants that are missing from VideoToolbox
    private enum VTConstants {
        static let hardwareAcceleratorOnly = "EnableHardwareAcceleratedVideoEncoder" as CFString
        static let priority = "Priority" as CFString
        static let priorityRealtimePreview = "RealtimePreview" as CFString
        
        // Color space constants for HEVC
        static let primariesITUR709 = "ITU_R_709_2"
        static let primariesBT2020 = "ITU_R_2020"
        static let yCbCrMatrix2020 = "ITU_R_2020"
        static let yCbCrMatrixITUR709 = "ITU_R_709_2"
        
        // HEVC Profile constants
        static let hevcMain422_10Profile = "HEVC_Main42210_AutoLevel"
    }
    
    private var encoderSpecification: [CFString: Any] {
        [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
    }
    
    // Store recording orientation
    private var recordingOrientation: CGFloat?
    
    override init() {
        super.init()
        print("\n=== Camera Initialization ===")
        
        // Add observer for flashlight settings changes
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .flashlightSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let settings = SettingsModel()
            if self.isRecording && settings.isFlashlightEnabled {
                self.flashlightManager.isEnabled = true
                self.flashlightManager.intensity = settings.flashlightIntensity
            } else {
                self.flashlightManager.isEnabled = false
            }
        }
        
        do {
            try setupSession()
            if let device = device {
                print("📊 Device Capabilities:")
                print("- Name: \(device.localizedName)")
                print("- Model ID: \(device.modelID)")
                
                isAppleLogSupported = device.formats.contains { format in
                    format.supportedColorSpaces.contains(.appleLog)
                }
                print("\n✅ Apple Log Support: \(isAppleLogSupported)")
            }
            print("=== End Initialization ===\n")
            
            if let device = device {
                defaultFormat = device.activeFormat
            }
            
            isAppleLogSupported = device?.formats.contains { format in
                format.supportedColorSpaces.contains(.appleLog)
            } ?? false
        } catch {
            self.error = .setupFailed
            print("Failed to setup session: \(error)")
        }
        
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                guard let self = self,
                      // Check connection availability early
                      let connection = self.videoDataOutput?.connection(with: .video) else { return }

                self.updateVideoOrientation(for: connection) // Pass connection only
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateShutterAngle(180.0)
        }
        
        print("📱 LUT Loading: No default LUTs will be loaded")
    }
    
    deinit {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        flashlightManager.cleanup()
    }
    
    private func findBestAppleLogFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        return device.formats.first { format in
            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            let codecType = CMFormatDescriptionGetMediaSubType(desc)
            
            let is4K = (dimensions.width == 3840 && dimensions.height == 2160)
            let isProRes422 = (codecType == kCMVideoCodecType_AppleProRes422)
            let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
            
            return is4K && isProRes422 && hasAppleLog
        }
    }
    
    private func configureAppleLog() async throws {
        print("\n=== Configuring Apple Log ===")
        
        guard let device = device else {
            print("❌ No camera device available")
            throw CameraError.configurationFailed
        }
        
        do {
            session.stopRunning()
            print("⏸️ Session stopped for reconfiguration")
            
            try await Task.sleep(for: .milliseconds(100))
            session.beginConfiguration()
            
            do {
                try device.lockForConfiguration()
            } catch {
                throw CameraError.configurationFailed
            }
            
            defer {
                device.unlockForConfiguration()
                session.commitConfiguration()
                
                if let videoConnection = videoDataOutput?.connection(with: .video) {
                    updateVideoOrientation(for: videoConnection)
                }
                
                session.startRunning()
            }
            
            // Check available codecs first
            let availableCodecs = videoDataOutput?.availableVideoCodecTypes ?? []
            print("📝 Available codecs: \(availableCodecs)")
            
            // Find a format that supports Apple Log
            let formats = device.formats.filter { format in
                let desc = format.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
                let matchesResolution = dimensions.width >= selectedResolution.dimensions.width &&
                                      dimensions.height >= selectedResolution.dimensions.height
                return hasAppleLog && matchesResolution
            }
            
            guard let selectedFormat = formats.first else {
                print("❌ No suitable Apple Log format found")
                throw CameraError.configurationFailed
            }
            
            print("✅ Found suitable Apple Log format")
            
            // Set the format first
            device.activeFormat = selectedFormat
            
            // Verify the format supports Apple Log
            guard selectedFormat.supportedColorSpaces.contains(.appleLog) else {
                print("❌ Selected format does not support Apple Log")
                throw CameraError.configurationFailed
            }
            
            print("✅ Format supports Apple Log")
            
            // Set frame duration
            let duration = CMTimeMake(value: 1000, timescale: Int32(selectedFrameRate * 1000))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            
            // Configure HDR if supported
            if selectedFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = true
                print("✅ Enabled HDR support")
            }
            
            // Set color space
            device.activeColorSpace = .appleLog
            print("✅ Set color space to Apple Log")
            
            // Update video configuration
            updateVideoConfiguration()
            print("🎬 Updated video configuration for codec: \(selectedCodec.rawValue)")
            
            print("✅ Successfully configured Apple Log format")
            
        } catch {
            print("❌ Error configuring Apple Log: \(error)")
            throw error
        }
        
        print("=== End Apple Log Configuration ===\n")
    }
    
    private func resetAppleLog() async throws {
        print("\n=== Resetting Apple Log ===")
        
        guard let device = device else {
            print("❌ No camera device available")
            throw CameraError.configurationFailed
        }
        
        do {
            session.stopRunning()
            print("⏸️ Session stopped for reconfiguration")
            
            try await Task.sleep(for: .milliseconds(100))
            session.beginConfiguration()
            
            do {
                try device.lockForConfiguration()
            } catch {
                throw CameraError.configurationFailed
            }
            
            defer {
                device.unlockForConfiguration()
                session.commitConfiguration()
                
                if let videoConnection = videoDataOutput?.connection(with: .video) {
                    updateVideoOrientation(for: videoConnection)
                }
                
                session.startRunning()
            }
            
            // Find a format that matches our resolution
            let formats = device.formats.filter { format in
                let desc = format.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                return dimensions.width >= selectedResolution.dimensions.width &&
                       dimensions.height >= selectedResolution.dimensions.height
            }
            
            guard let selectedFormat = formats.first else {
                print("❌ No suitable format found")
                throw CameraError.configurationFailed
            }
            
            print("✅ Found suitable format")
            
            // Set the format
            device.activeFormat = selectedFormat
            
            // Set frame duration
            let duration = CMTimeMake(value: 1000, timescale: Int32(selectedFrameRate * 1000))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            
            // Reset HDR settings
            if selectedFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = true
                print("✅ Reset HDR settings")
            }
            
            // Reset color space
            device.activeColorSpace = .sRGB
            print("✅ Reset color space to sRGB")
            
            // Update video configuration
            updateVideoConfiguration()
            print("🎬 Updated video configuration for codec: \(selectedCodec.rawValue)")
            
            print("✅ Successfully reset Apple Log format")
            
        } catch {
            print("❌ Error resetting Apple Log: \(error)")
            throw error
        }
        
        print("=== End Apple Log Reset ===\n")
    }
    
    private func setupSession() throws {
        print("DEBUG: 🎥 Setting up camera session")
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.beginConfiguration()
        
        // Get available lenses
        availableLenses = CameraLens.availableLenses()
        print("DEBUG: 📸 Available lenses: \(availableLenses.map { $0.rawValue }.joined(separator: ", "))")
        
        // Start with wide angle camera
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .back) else {
            print("DEBUG: ❌ No camera device available")
            error = .cameraUnavailable
            status = .failed
            session.commitConfiguration()
            return
        }
        
        print("DEBUG: ✅ Found camera device: \(videoDevice.localizedName)")
        self.device = videoDevice
        
        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            self.videoDeviceInput = input
            
            // Always try to set up Apple Log format initially
            if let appleLogFormat = findBestAppleLogFormat(videoDevice) {
                let frameRateRange = appleLogFormat.videoSupportedFrameRateRanges.first!
                try videoDevice.lockForConfiguration()
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.maxFrameRate))
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.minFrameRate))
                videoDevice.activeFormat = appleLogFormat
                videoDevice.activeColorSpace = .appleLog
                print("Initial setup: Enabled Apple Log in 4K ProRes format")
                videoDevice.unlockForConfiguration()
            } else {
                print("Initial setup: Apple Log format not available")
                isAppleLogEnabled = false
            }
            
            if session.canAddInput(input) {
                session.addInput(input)
                print("DEBUG: ✅ Added video input to session")
            } else {
                print("DEBUG: ❌ Failed to add video input to session")
            }
            
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
                print("DEBUG: ✅ Added audio input to session")
            }
            
            // Add video data output for AVAssetWriter
            let videoDataOutput = AVCaptureVideoDataOutput()
            videoDataOutput.setSampleBufferDelegate(self, queue: processingQueue)
            
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
                print("DEBUG: ✅ Added video data output to session")
                
                // Configure initial video settings
                updateVideoConfiguration()
            } else {
                print("DEBUG: ❌ Failed to add video data output to session")
            }
            
            if let device = device {
                try device.lockForConfiguration()
                let duration = CMTimeMake(value: 1000, timescale: Int32(selectedFrameRate * 1000))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                print("DEBUG: ✅ Set frame rate to \(selectedFrameRate) fps")
            }
            
        } catch {
            print("Error setting up camera: \(error)")
            self.error = .setupFailed
            session.commitConfiguration()
            return
        }
        
        session.commitConfiguration()
        print("DEBUG: ✅ Session configuration committed")
        
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
            print("DEBUG: ✅ Using 4K preset")
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
            print("DEBUG: ✅ Using 1080p preset")
        }
        
        // Request camera permissions if needed
        checkCameraPermissionsAndStart()
        
        isAppleLogSupported = device?.formats.contains { format in
            format.supportedColorSpaces.contains(.appleLog)
        } ?? false
        
        defaultFormat = device?.activeFormat
    }
    
    private func checkCameraPermissionsAndStart() {
        let cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch cameraAuthorizationStatus {
        case .authorized:
            print("DEBUG: ✅ Camera access already authorized")
            startCameraSession()
            
        case .notDetermined:
            print("DEBUG: 🔄 Requesting camera authorization...")
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    print("DEBUG: ✅ Camera access granted")
                    self.startCameraSession()
                } else {
                    print("DEBUG: ❌ Camera access denied")
                    DispatchQueue.main.async {
                        self.error = .unauthorized
                        self.status = .unauthorized
                    }
                }
            }
            
        case .denied, .restricted:
            print("DEBUG: ❌ Camera access denied or restricted")
            DispatchQueue.main.async {
                self.error = .unauthorized
                self.status = .unauthorized
            }
            
        @unknown default:
            print("DEBUG: ❓ Unknown camera authorization status")
            startCameraSession()
        }
    }
    
    private func startCameraSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            print("DEBUG: 🎬 Starting camera session...")
            if !self.session.isRunning {
                self.session.startRunning()
                
                DispatchQueue.main.async {
                    self.isSessionRunning = self.session.isRunning
                    self.status = self.session.isRunning ? .running : .failed
                    print("DEBUG: 📷 Camera session running: \(self.session.isRunning)")
                }
            } else {
                print("DEBUG: ⚠️ Camera session already running")
                
                DispatchQueue.main.async {
                    self.isSessionRunning = true
                    self.status = .running
                }
            }
        }
    }
    
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
    
    func updateISO(_ iso: Float) {
        guard let device = device else { return }
        
        // Get the current device's supported ISO range
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        
        print("DEBUG: ISO update requested to \(iso). Device supports range: \(minISO) to \(maxISO)")
        
        // Ensure the ISO value is within the supported range
        let clampedISO = min(max(minISO, iso), maxISO)
        
        // Log if clamping occurred
        if clampedISO != iso {
            print("DEBUG: Clamped ISO from \(iso) to \(clampedISO) to stay within device limits")
        }
        
        do {
            try device.lockForConfiguration()
            
            // Double check that we're within range before setting
            device.setExposureModeCustom(duration: device.exposureDuration, iso: clampedISO) { _ in }
            device.unlockForConfiguration()
            
            // Update the published property with the actual value used
            DispatchQueue.main.async {
                self.iso = clampedISO
            }
            
            print("DEBUG: Successfully set ISO to \(clampedISO)")
        } catch {
            print("❌ ISO error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    func updateShutterSpeed(_ speed: CMTime) {
        guard let device = device else { return }
        do {
            try device.lockForConfiguration()
            
            // Get the current device's supported ISO range
            let minISO = device.activeFormat.minISO
            let maxISO = device.activeFormat.maxISO
            
            // Get current ISO value, either from device or our stored value
            let currentISO = device.iso
            
            // Ensure the ISO value is within the supported range
            let clampedISO = min(max(minISO, currentISO), maxISO)
            
            // If ISO is 0 or outside valid range, use our stored value or minISO as fallback
            let safeISO: Float
            if clampedISO <= 0 {
                safeISO = max(self.iso, minISO)
                print("DEBUG: Corrected invalid ISO \(currentISO) to \(safeISO)")
            } else {
                safeISO = clampedISO
            }
            
            device.setExposureModeCustom(duration: speed, iso: safeISO) { _ in }
            device.unlockForConfiguration()
            
            DispatchQueue.main.async {
                self.shutterSpeed = speed
                // Update our stored ISO if we had to correct it
                if safeISO != currentISO {
                    self.iso = safeISO
                }
            }
        } catch {
            print("❌ Shutter speed error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    @MainActor
    func startRecording() async {
        guard !isRecording else { return }
        
        // Store current orientation when starting recording
        if let videoConnection = videoDataOutput?.connection(with: .video) {
            recordingOrientation = videoConnection.videoRotationAngle
            print("🔒 Stored recording orientation: \(recordingOrientation ?? 0)°")
        }
        
        // Lock orientation updates
        recordingOrientationLocked = true
        print("🔒 Orientation updates locked for recording.")
        
        // Reset counters when starting a new recording
        videoFrameCount = 0
        audioFrameCount = 0
        successfulVideoFrames = 0
        failedVideoFrames = 0
        
        do {
            // Create temporary URL for recording
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "recording_\(Date().timeIntervalSince1970).mov"
            let tempURL = tempDir.appendingPathComponent(fileName)
            currentRecordingURL = tempURL
            
            print("🎬 START RECORDING: Creating asset writer at \(tempURL.path)")
            
            // Create asset writer
            assetWriter = try AVAssetWriter(url: tempURL, fileType: .mov)
            
            // Get dimensions from current format
            guard let device = device else {
                print("❌ ERROR: Camera device is nil in startRecording")
                throw CameraError.configurationFailed
            }
            
            // Get active format (not optional)
            let format = device.activeFormat
            
            // Now safely get dimensions (which are optional)
            guard let dimensions = format.dimensions else {
                print("❌ ERROR: Could not get dimensions from active format: \(format)")
                throw CameraError.configurationFailed
            }
            
            // Set dimensions based on the native format dimensions
            let videoWidth = dimensions.width
            let videoHeight = dimensions.height
            
            // Configure video settings based on current configuration
            var videoSettings: [String: Any] = [
                AVVideoWidthKey: videoWidth,  // Use native width
                AVVideoHeightKey: videoHeight // Use native height
            ]
            
            if selectedCodec == .proRes {
                videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
                // ProRes doesn't use compression properties
            } else {
                videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
                
                // Create a single dictionary for all compression properties
                let compressionProperties: [String: Any] = [
                    AVVideoAverageBitRateKey: selectedCodec.bitrate,
                    AVVideoExpectedSourceFrameRateKey: NSNumber(value: selectedFrameRate),
                    AVVideoMaxKeyFrameIntervalKey: Int(selectedFrameRate), // One keyframe per second
                    AVVideoMaxKeyFrameIntervalDurationKey: 1.0, // Force keyframe every second
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: VTConstants.hevcMain422_10Profile,
                    AVVideoColorPrimariesKey: isAppleLogEnabled ? VTConstants.primariesBT2020 : VTConstants.primariesITUR709,
                    AVVideoYCbCrMatrixKey: isAppleLogEnabled ? VTConstants.yCbCrMatrix2020 : VTConstants.yCbCrMatrixITUR709,
                    "AllowOpenGOP": false,
                    "EncoderID": "com.apple.videotoolbox.videoencoder.hevc.422v2"
                ]
                
                videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties
            }
            
            // Create video input with better buffer handling
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true

            print("📝 Created asset writer input with settings: \(videoSettings)")
            
            // Log the video connection's rotation angle before starting
            if let videoConnection = self.videoDataOutput?.connection(with: .video) {
                print("DEBUG: Video connection angle before starting writer: \(videoConnection.videoRotationAngle)°")
            } else {
                print("DEBUG: Could not get video connection before starting writer.")
            }
            
            // Configure audio settings
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            
            // Create audio input
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            
            // Create pixel buffer adaptor with appropriate format
            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            
            assetWriterPixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: assetWriterInput!,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
            
            print("📐 Created pixel buffer adaptor with format: BGRA (32-bit)")
            
            // Add inputs to writer
            if assetWriter!.canAdd(assetWriterInput!) {
                assetWriter!.add(assetWriterInput!)
                print("✅ Added video input to asset writer")
            } else {
                print("❌ FAILED to add video input to asset writer")
            }
            
            if assetWriter!.canAdd(audioInput) {
                assetWriter!.add(audioInput)
                print("✅ Added audio input to asset writer")
            } else {
                print("❌ FAILED to add audio input to asset writer")
            }
            
            // Configure video data output if not already configured
            if videoDataOutput == nil {
                videoDataOutput = AVCaptureVideoDataOutput()
                videoDataOutput?.setSampleBufferDelegate(self, queue: processingQueue)
                if session.canAddOutput(videoDataOutput!) {
                    session.addOutput(videoDataOutput!)
                    print("✅ Added video data output to session")
                } else {
                    print("❌ FAILED to add video data output to session")
                }
            } else {
                print("✅ Using existing video data output")
            }
            
            // Configure audio data output if not already configured
            if audioDataOutput == nil {
                audioDataOutput = AVCaptureAudioDataOutput()
                audioDataOutput?.setSampleBufferDelegate(self, queue: processingQueue)
                if session.canAddOutput(audioDataOutput!) {
                    session.addOutput(audioDataOutput!)
                    print("✅ Added audio data output to session")
                } else {
                    print("❌ FAILED to add audio data output to session")
                }
            } else {
                print("✅ Using existing audio data output")
            }
            
            // Start writing
            recordingStartTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000000)
            assetWriter!.startWriting()
            assetWriter!.startSession(atSourceTime: recordingStartTime!)
            
            print("▶️ Started asset writer session at time: \(recordingStartTime!.seconds)")
            
            isRecording = true
            print("✅ Started recording to: \(tempURL.path)")
            print("📊 Recording settings:")
            // Log the actual dimensions being used by the writer
            print("- Resolution: \(videoWidth)x\(videoHeight) (Writer Dimensions)")
            print("- Codec: \(selectedCodec == .proRes ? "ProRes 422 HQ" : "HEVC")")
            print("- Color Space: \(isAppleLogEnabled ? "Apple Log (BT.2020)" : "Rec.709")")
            print("- Chroma subsampling: 4:2:2")
            print("- Frame Rate: \(selectedFrameRate) fps")
            print("- Start Time: \(recordingStartTime!.seconds)")
            
        } catch {
            self.error = .recordingFailed
            print("❌ Failed to start recording: \(error)")
        }
    }
    
    @MainActor
    func stopRecording() async {
        guard isRecording else { return }
        
        // Clear stored recording orientation
        recordingOrientation = nil
        print("🔓 Cleared recording orientation")
        
        print("⏹️ STOP RECORDING: Finalizing video with \(videoFrameCount) frames (\(successfulVideoFrames) successful, \(failedVideoFrames) failed)")
        
        isProcessingRecording = true
        
        // Mark all inputs as finished
        assetWriterInput?.markAsFinished()
        print("✅ Marked asset writer inputs as finished")
        
        // Wait for asset writer to finish
        if let assetWriter = assetWriter {
            print("⏳ Waiting for asset writer to finish writing...")
            await assetWriter.finishWriting()
            print("✅ Asset writer finished with status: \(assetWriter.status.rawValue)")
            
            if let error = assetWriter.error {
                print("❌ Asset writer error: \(error)")
            }
        }
        
        // Clean up recording resources
        if let videoDataOutput = videoDataOutput {
            session.removeOutput(videoDataOutput)
            self.videoDataOutput = nil
            print("🧹 Removed video data output from session")
        }
        
        if let audioDataOutput = audioDataOutput {
            session.removeOutput(audioDataOutput)
            self.audioDataOutput = nil
            print("🧹 Removed audio data output from session")
        }
        
        // Reset recording state
        isRecording = false
        recordingStartTime = nil
        
        // Save to photo library if we have a valid recording
        if let outputURL = currentRecordingURL {
            print("💾 Saving video to photo library: \(outputURL.path)")
            
            // Check file size
            let fileManager = FileManager.default
            if let attributes = try? fileManager.attributesOfItem(atPath: outputURL.path),
               let fileSize = attributes[.size] as? Int {
                print("📊 Video file size: \(fileSize / 1024 / 1024) MB")
            }
            
            // Check duration using AVAsset
            let asset = AVURLAsset(url: outputURL)
            Task {
                let duration = try? await asset.load(.duration)
                if let duration = duration {
                    print("⏱️ Video duration: \(CMTimeGetSeconds(duration)) seconds")
                }
            }
            
            await saveToPhotoLibrary(outputURL)
        }
        
        // Unlock orientation updates
        recordingOrientationLocked = false
        print("🔓 Orientation updates unlocked.")
        // Trigger an orientation update based on the current device state
        if let connection = self.videoDataOutput?.connection(with: .video) {
            self.updateVideoOrientation(for: connection)
        }

        // Clean up
        assetWriter = nil
        assetWriterInput = nil
        assetWriterPixelBufferAdaptor = nil
        currentRecordingURL = nil
        isProcessingRecording = false
        
        print("🏁 Recording session completed")
    }
    
    private func saveToPhotoLibrary(_ outputURL: URL) async {
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized else {
                await MainActor.run {
                    self.error = .savingFailed
                    print("Photo library access denied")
                }
                return
            }
            
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .video, fileURL: outputURL, options: options)
            }
            
            await MainActor.run {
                print("Video saved to photo library")
                self.recordingFinished = true
            }
        } catch {
            await MainActor.run {
                print("Error saving video: \(error)")
                self.error = .savingFailed
            }
        }
    }
    
    private func generateThumbnail(from videoURL: URL) {
        let asset = AVURLAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        // Get thumbnail from first frame
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        
        // Use async thumbnail generation
        imageGenerator.generateCGImageAsynchronously(for: time) { [weak self] cgImage, actualTime, error in
            if let error = error {
                print("Error generating thumbnail: \(error)")
                return
            }
            
            if let cgImage = cgImage {
                DispatchQueue.main.async {
                    self?.lastRecordedVideoThumbnail = UIImage(cgImage: cgImage)
                }
            }
        }
    }
    
    private func updateVideoOrientation(for connection: AVCaptureConnection) {
        // Add check here: If orientation is locked during recording, do nothing.
        guard !recordingOrientationLocked else {
            print("🔄 Orientation update skipped: Recording in progress.")
            return
        }

        let deviceOrientation = UIDevice.current.orientation
        let newAngle: CGFloat

        switch deviceOrientation {
        case .portrait:
            newAngle = 90
        case .landscapeLeft:
            newAngle = 0
        case .landscapeRight:
            newAngle = 180
        case .portraitUpsideDown:
            newAngle = 270
        case .faceUp, .faceDown, .unknown:
            // Don't change angle if orientation is ambiguous
            // Keep the current angle
            print("DEBUG: Ambiguous orientation (\(deviceOrientation.rawValue)), maintaining current videoRotationAngle: \(connection.videoRotationAngle)°")
            newAngle = connection.videoRotationAngle // Keep current angle
        @unknown default:
            print("DEBUG: Unknown device orientation (\(deviceOrientation.rawValue)), defaulting videoRotationAngle to 90°")
            newAngle = 90 // Default to portrait
        }

        // Check if the new angle is supported
        guard connection.isVideoRotationAngleSupported(newAngle) else {
             print("⚠️ Rotation angle \(newAngle)° not supported for connection.")
             // Optionally, try a default like 90 if the calculated one isn't supported?
             // For now, just return if not supported.
             return
        }

        // Only update if the angle is actually different
        if connection.videoRotationAngle != newAngle {
            connection.videoRotationAngle = newAngle
            print("🔄 Updated video connection rotation angle to \(newAngle)° based on device orientation \(deviceOrientation.rawValue)")
        } else {
             // Optional: Log that the angle is already correct
             // print("DEBUG: Video connection rotation angle already \(newAngle)° for device orientation \(deviceOrientation.rawValue)")
        }
    }
    
    private func findCompatibleFormat(for fps: Double) -> AVCaptureDevice.Format? {
        guard let device = device else { return nil }
        
        let targetFps = fps
        let tolerance = 0.01
        
        let formats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let isHighRes = dimensions.width >= 1920
            let supportsFrameRate = format.videoSupportedFrameRateRanges.contains { range in
                if abs(targetFps - 23.976) < 0.001 {
                    return range.minFrameRate <= (targetFps - tolerance) &&
                           (targetFps + tolerance) <= range.maxFrameRate
                } else {
                    return range.minFrameRate <= targetFps && targetFps <= range.maxFrameRate
                }
            }
            
            if isAppleLogEnabled {
                return isHighRes && supportsFrameRate && format.supportedColorSpaces.contains(.appleLog)
            }
            return isHighRes && supportsFrameRate
        }
        
        return formats.first
    }
    
    func updateFrameRate(_ fps: Double) {
        guard let device = device else { return }
        
        do {
            guard let compatibleFormat = findCompatibleFormat(for: fps) else {
                print("❌ No compatible format found for \(fps) fps")
                DispatchQueue.main.async {
                    self.error = .configurationFailed(message: "This device doesn't support \(fps) fps recording")
                }
                return
            }
            
            try device.lockForConfiguration()
            
            if device.activeFormat != compatibleFormat {
                print("Switching to compatible format...")
                device.activeFormat = compatibleFormat
            }
            
            let frameDuration: CMTime
            switch fps {
            case 23.976:
                frameDuration = FrameRates.ntsc23_976
                print("Setting 23.976 fps with duration \(FrameRates.ntsc23_976.value)/\(FrameRates.ntsc23_976.timescale)")
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
            
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.selectedFrameRate = fps
                self.frameCount = 0
                self.frameRateAccumulator = 0
                self.lastFrameTime = nil
            }
            
            device.unlockForConfiguration()
            
            let currentAngle = shutterAngle
            updateShutterAngle(currentAngle)
        } catch {
            print("❌ Frame rate error: \(error)")
            self.error = .configurationFailed(message: "Failed to set \(fps) fps: \(error.localizedDescription)")
        }
    }
    
    private func adjustFrameRatePrecision(currentFPS: Double) {
        let deviation = abs(currentFPS - selectedFrameRate) / selectedFrameRate
        guard deviation > 0.02 else { return }
        
        let now = Date().timeIntervalSince1970
        guard (now - lastAdjustmentTime) > 1.0 else { return }
        
        lastAdjustmentTime = now
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateFrameRate(self.selectedFrameRate)
        }
    }
    
    private var lastAdjustmentTime: TimeInterval = 0
    
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
            
            if device.activeFormat.isVideoStabilizationModeSupported(.cinematic) {
                if let connection = videoDataOutput?.connection(with: .video),
                   connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .cinematic
                }
            }
            
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            
            // Only set auto exposure if we're in auto mode
            if isAutoExposureEnabled {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            } else {
                // If in manual mode, ensure we have a valid ISO value
                if device.isExposureModeSupported(.custom) {
                    // Get the current device's supported ISO range
                    let minISO = device.activeFormat.minISO
                    let maxISO = device.activeFormat.maxISO
                    
                    // Ensure the ISO value is within the supported range
                    let clampedISO = min(max(minISO, self.iso), maxISO)
                    
                    // Update our stored value if needed
                    if clampedISO != self.iso {
                        print("DEBUG: Optimizing video - Clamped ISO from \(self.iso) to \(clampedISO)")
                        DispatchQueue.main.async {
                            self.iso = clampedISO
                        }
                    }
                    
                    device.exposureMode = .custom
                    device.setExposureModeCustom(duration: device.exposureDuration, 
                                                iso: clampedISO) { _ in }
                }
            }
            
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
                
                let currentGains = device.deviceWhiteBalanceGains
                var newGains = currentGains
                let tintScale = currentTint / 150.0
                
                if tintScale > 0 {
                    newGains.greenGain = currentGains.greenGain * (1.0 + Float(tintScale))
                } else {
                    let magentaScale = 1.0 + Float(abs(tintScale))
                    newGains.redGain = currentGains.redGain * magentaScale
                    newGains.blueGain = currentGains.blueGain * magentaScale
                }
                
                let maxGain = device.maxWhiteBalanceGain
                newGains.redGain = min(max(1.0, newGains.redGain), maxGain)
                newGains.greenGain = min(max(1.0, newGains.greenGain), maxGain)
                newGains.blueGain = min(max(1.0, newGains.blueGain), maxGain)
                
                device.setWhiteBalanceModeLocked(with: newGains) { _ in }
            }
            device.unlockForConfiguration()
        } catch {
            print("Error setting tint: \(error.localizedDescription)")
            self.error = .whiteBalanceError
        }
    }
    
    func updateTint(_ newValue: Double) {
        currentTint = newValue.clamped(to: tintRange)
        configureTintSettings()
    }

    var shutterAngle: Double {
        get {
            let angle = Double(shutterSpeed.value) / Double(shutterSpeed.timescale) * selectedFrameRate * 360.0
            let clampedAngle = min(max(angle, 1.1), 360.0)
            return clampedAngle
        }
        set {
            let clampedAngle = min(max(newValue, 1.1), 360.0)
            let duration = (clampedAngle/360.0) * (1.0/selectedFrameRate)
            let time = CMTimeMakeWithSeconds(duration, preferredTimescale: 1000000)
            updateShutterSpeed(time)
            DispatchQueue.main.async {
                self.shutterSpeed = time
            }
        }
    }
    
    func updateShutterAngle(_ angle: Double) {
        self.shutterAngle = angle
    }
    
    private func updateExposureMode() {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            
            if isAutoExposureEnabled {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                    print("📷 Auto exposure enabled")
                }
            } else {
                if device.isExposureModeSupported(.custom) {
                    device.exposureMode = .custom
                    
                    // Double check ISO range limits
                    let minISO = device.activeFormat.minISO
                    let maxISO = device.activeFormat.maxISO
                    let clampedISO = min(max(minISO, self.iso), maxISO)
                    
                    if clampedISO != self.iso {
                        print("DEBUG: Exposure mode - Clamped ISO from \(self.iso) to \(clampedISO)")
                        DispatchQueue.main.async {
                            self.iso = clampedISO
                        }
                    }
                    
                    device.setExposureModeCustom(duration: device.exposureDuration,
                                                 iso: clampedISO) { _ in }
                    print("📷 Manual exposure enabled with ISO \(clampedISO)")
                }
            }
            
            device.unlockForConfiguration()
        } catch {
            print("❌ Error setting exposure mode: \(error.localizedDescription)")
            self.error = .configurationFailed
        }
    }
    
    func processVideoFrame(_ sampleBuffer: CMSampleBuffer) -> CIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("DEBUG: No pixel buffer in sample buffer")
            return nil
        }
        
        // Create CIImage from the pixel buffer
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Apply LUT filter if available
        if let lutFilter = lutManager.currentLUTFilter {
            lutFilter.setValue(ciImage, forKey: kCIInputImageKey)
            if let outputImage = lutFilter.outputImage {
                return outputImage
            } else {
                // If LUT application fails, return the original image
                print("DEBUG: LUT filter failed to produce output image, using original")
                return ciImage
            }
        }
        
        // No LUT filter applied, return original image
        return ciImage
    }
    
    func updateOrientation(_ orientation: UIInterfaceOrientation) {
        self.currentInterfaceOrientation = orientation
        // Do NOT call camera update logic from here anymore
        // updateInterfaceOrientation()
        // Instead, UI elements should observe currentInterfaceOrientation
        print("DEBUG: UI Interface orientation updated to: \(orientation.rawValue)")
    }
    
    private func updateVideoConfiguration() {
        print("\n=== Updating Video Configuration ===")
        print("🎬 Selected Codec: \(selectedCodec.rawValue)")
        print("🎨 Apple Log Enabled: \(isAppleLogEnabled)")
        
        // Configure video settings based on codec
        if selectedCodec == .proRes {
            print("✅ Configured for ProRes recording")
            print("📊 Using codec: ProRes 422 HQ")
        } else {
            print("✅ Configured for HEVC recording")
            print("📊 Configured with:")
            print("- Codec: HEVC")
            print("- Bitrate: \(selectedCodec.bitrate / 1_000_000) Mbps")
            print("- Frame Rate: \(selectedFrameRate) fps")
            print("- Color Space: \(isAppleLogEnabled ? "Apple Log (BT.2020)" : "Rec.709")")
            print("- Matrix: \(isAppleLogEnabled ? "BT.2020 non-constant" : "Rec.709")")
            print("- Transfer: Apple Log")
            print("- Chroma subsampling: 4:2:2")
            print("- Profile Level: \(isAppleLogEnabled ? "HEVC_Main42210_AutoLevel" : "HEVC_Main_AutoLevel")")
        }
        
        print("=== End Video Configuration ===\n")
    }

    private func applyLUT(to image: CIImage, using lutFilter: CIFilter) -> CIImage? {
        lutFilter.setValue(image, forKey: kCIInputImageKey)
        return lutFilter.outputImage
    }
    
    private func updateCameraFormat(for resolution: Resolution) async throws {
        guard let device = device else { return }
        
        print("\n=== Updating Camera Format ===")
        print("🎯 Target Resolution: \(resolution.rawValue)")
        print("🎥 Current Frame Rate: \(selectedFrameRate)")
        
        let wasRunning = session.isRunning
        if wasRunning {
            session.stopRunning()
        }
        
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            // Find all formats that match our resolution
            let matchingFormats = device.formats.filter { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dimensions.width == resolution.dimensions.width &&
                       dimensions.height == resolution.dimensions.height
            }
            
            print("📊 Found \(matchingFormats.count) matching formats")
            
            // Find the best format that supports our current frame rate
            let bestFormat = matchingFormats.first { format in
                format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate...range.maxFrameRate ~= selectedFrameRate
                }
            } ?? matchingFormats.first
            
            guard let selectedFormat = bestFormat else {
                print("❌ No compatible format found for resolution \(resolution.rawValue)")
                if wasRunning {
                    session.startRunning()
                }
                throw CameraError.configurationFailed
            }
            
            // Begin configuration
            session.beginConfiguration()
            
            // Set the format
            device.activeFormat = selectedFormat
            
            // Set the frame duration
            let duration = CMTime(value: 1, timescale: CMTimeScale(selectedFrameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            
            // Update video configuration
            updateVideoConfiguration()
            
            // Commit the configuration
            session.commitConfiguration()
            
            // Restore session state if it was running
            if wasRunning {
                session.startRunning()
            }
            
            print("✅ Camera format updated successfully")
            print("=== End Update ===\n")
            
        } catch {
            print("❌ Error updating camera format: \(error.localizedDescription)")
            session.commitConfiguration()
            
            if wasRunning {
                session.startRunning()
            }
            
            throw error
        }
    }
    
    func switchToLens(_ lens: CameraLens) {
        print("DEBUG: 🔄 Switching to \(lens.rawValue)× lens")
        
        // For 2x zoom, we use digital zoom on the wide angle camera
        if lens == .x2 {
            guard let currentDevice = device,
                  currentDevice.deviceType == .builtInWideAngleCamera else {
                // Switch to wide angle first if we're not already on it
                switchToLens(.wide)
                return
            }
            
            do {
                try currentDevice.lockForConfiguration()
                currentDevice.ramp(toVideoZoomFactor: lens.zoomFactor, withRate: 20.0)
                currentDevice.unlockForConfiguration()
                currentLens = lens
                currentZoomFactor = lens.zoomFactor
                print("DEBUG: ✅ Set digital zoom to 2x")
            } catch {
                print("DEBUG: ❌ Failed to set digital zoom: \(error)")
                self.error = .configurationFailed
            }
            return
        }
        
        guard let newDevice = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
            print("DEBUG: ❌ Failed to get device for \(lens.rawValue)× lens")
            return
        }
        
        session.beginConfiguration()
        
        // Remove existing input
        if let currentInput = videoDeviceInput {
            session.removeInput(currentInput)
        }
        
        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                videoDeviceInput = newInput
                device = newDevice
                currentLens = lens
                currentZoomFactor = lens.zoomFactor
                
                // Reset zoom factor when switching physical lenses
                try newDevice.lockForConfiguration()
                newDevice.videoZoomFactor = 1.0
                let duration = CMTimeMake(value: 1000, timescale: Int32(selectedFrameRate * 1000))
                newDevice.activeVideoMinFrameDuration = duration
                newDevice.activeVideoMaxFrameDuration = duration
                newDevice.unlockForConfiguration()
                
                print("DEBUG: ✅ Successfully switched to \(lens.rawValue)× lens")
                
                // Update video orientation for the new connection
                if let connection = videoDataOutput?.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }
                    
                    // Only update orientation if NOT recording
                    if !isRecording {
                        // Update the orientation based on the current device state.
                        updateVideoOrientation(for: connection)
                    }
                }
            } else {
                print("DEBUG: ❌ Cannot add input for \(lens.rawValue)× lens")
            }
        } catch {
            print("DEBUG: ❌ Error switching to \(lens.rawValue)× lens: \(error)")
            self.error = .configurationFailed
        }
        
        session.commitConfiguration()
    }
    
    func setZoomFactor(_ factor: CGFloat) {
        guard let currentDevice = device else { return }
        
        // Find the appropriate lens based on the zoom factor
        let targetLens = availableLenses
            .sorted { abs($0.zoomFactor - factor) < abs($1.zoomFactor - factor) }
            .first ?? .wide
        
        // If we need to switch lenses
        if targetLens != currentLens && abs(targetLens.zoomFactor - factor) < 0.5 {
            switchToLens(targetLens)
            return
        }
        
        do {
            try currentDevice.lockForConfiguration()
            
            // Calculate zoom factor relative to the current lens
            let baseZoom = currentLens.zoomFactor
            let relativeZoom = factor / baseZoom
            let zoomFactor = min(max(relativeZoom, currentDevice.minAvailableVideoZoomFactor),
                               currentDevice.maxAvailableVideoZoomFactor)
            
            // Apply zoom smoothly
            currentDevice.ramp(toVideoZoomFactor: zoomFactor,
                             withRate: 20.0)
            
            currentZoomFactor = factor
            lastZoomFactor = zoomFactor
            
            currentDevice.unlockForConfiguration()
        } catch {
            print("DEBUG: ❌ Failed to set zoom: \(error)")
            self.error = .configurationFailed
        }
    }
    
    private func setupHEVCEncoder() throws {
        print("\n=== Setting up HEVC Hardware Encoder ===")
        
        // Clean up any existing session
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        
        // Get dimensions from the active format
        guard let device = device,
              let dimensions = device.activeFormat.dimensions else {
            throw CameraError.configurationFailed
        }
        
        // Create compression session
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(dimensions.width),
            height: Int32(dimensions.height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { outputCallbackRefCon, sourceFrameRefCon, status, flags, sampleBuffer in
                if sampleBuffer != nil {
                    DispatchQueue.main.async {
                        print("✅ Encoded HEVC frame received")
                    }
                }
            },
            refcon: nil,
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            print("❌ Failed to create compression session: \(status)")
            throw CameraError.configurationFailed
        }
        
        // Configure encoder properties
        let properties: [String: Any] = [
            kVTCompressionPropertyKey_RealTime.string: true,
            kVTCompressionPropertyKey_ProfileLevel.string: VTConstants.hevcMain422_10Profile,
            kVTCompressionPropertyKey_MaxKeyFrameInterval.string: Int32(selectedFrameRate),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration.string: 1,
            kVTCompressionPropertyKey_AllowFrameReordering.string: false,
            VTConstants.priority.string: VTConstants.priorityRealtimePreview,
            kVTCompressionPropertyKey_AverageBitRate.string: selectedCodec.bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate.string: selectedFrameRate,
            kVTCompressionPropertyKey_ColorPrimaries.string: isAppleLogEnabled ? VTConstants.primariesBT2020 : VTConstants.primariesITUR709,
            kVTCompressionPropertyKey_YCbCrMatrix.string: isAppleLogEnabled ? VTConstants.yCbCrMatrix2020 : VTConstants.yCbCrMatrixITUR709,
            kVTCompressionPropertyKey_EncoderID.string: "com.apple.videotoolbox.videoencoder.hevc.422v2"
        ]
        
        // Apply properties
        for (key, value) in properties {
            let propStatus = VTSessionSetProperty(session, key: key as CFString, value: value as CFTypeRef)
            if propStatus != noErr {
                print("⚠️ Failed to set property \(key): \(propStatus)")
            }
        }
        
        // Prepare to encode frames
        VTCompressionSessionPrepareToEncodeFrames(session)
        
        // Store the session
        compressionSession = session
        print("✅ HEVC Hardware encoder setup complete")
        print("=== End HEVC Encoder Setup ===\n")
    }
    
    private func encodeFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let compressionSession = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CMSampleBufferGetFormatDescription(sampleBuffer) != nil else {
            return
        }
        
        // Get frame timing info
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
        
        // Create properties for encoding
        var properties: [String: Any] = [:]
        if CMSampleBufferGetNumSamples(sampleBuffer) > 0 {
            properties[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true
        }
        
        // Encode the frame
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: timing.presentationTimeStamp,
            duration: timing.duration,
            frameProperties: properties as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        
        if status != noErr {
            print("⚠️ Failed to encode frame: \(status)")
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    // Track frame counts for logging
    private var videoFrameCount = 0
    private var audioFrameCount = 0
    private var successfulVideoFrames = 0
    private var failedVideoFrames = 0
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let assetWriter = assetWriter,
              assetWriter.status == .writing else {
            return
        }
        
        // Handle video data
        if output == videoDataOutput,
           let assetWriterInput = assetWriterInput,
           assetWriterInput.isReadyForMoreMediaData {
            
            videoFrameCount += 1
            
            // Log every 30 frames to avoid flooding
            let shouldLog = videoFrameCount % 30 == 0
            if shouldLog {
                print("📽️ Processing video frame #\(videoFrameCount), writer status: \(assetWriter.status.rawValue)")
            }
            
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                if let lutFilter = tempLUTFilter ?? lutManager.currentLUTFilter {
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    if let processedImage = applyLUT(to: ciImage, using: lutFilter),
                       let processedPixelBuffer = createPixelBuffer(from: processedImage, with: pixelBuffer) {
                        
                        // Use original timing information
                        var timing = CMSampleTimingInfo()
                        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
                        
                        // Create format description for processed buffer
                        var info: CMFormatDescription?
                        let status = CMVideoFormatDescriptionCreateForImageBuffer(
                            allocator: kCFAllocatorDefault,
                            imageBuffer: processedPixelBuffer,
                            formatDescriptionOut: &info
                        )
                        
                        if status == noErr, let info = info,
                           let newSampleBuffer = createSampleBuffer(
                            from: processedPixelBuffer,
                            formatDescription: info,
                            timing: &timing
                           ) {
                            assetWriterInput.append(newSampleBuffer)
                            successfulVideoFrames += 1
                            if shouldLog {
                                print("✅ Successfully appended processed frame #\(successfulVideoFrames)")
                            }
                        } else {
                            failedVideoFrames += 1
                            print("⚠️ Failed to create format description for processed frame #\(videoFrameCount), status: \(status)")
                        }
                    }
                } else {
                    // No LUT processing needed - use original sample buffer directly
                    assetWriterInput.append(sampleBuffer)
                    successfulVideoFrames += 1
                    if shouldLog {
                        print("✅ Successfully appended original frame #\(successfulVideoFrames)")
                    }
                }
            }
        }
        
        // Handle audio data
        if output == audioDataOutput,
           let audioInput = assetWriter.inputs.first(where: { $0.mediaType == .audio }),
           audioInput.isReadyForMoreMediaData {
            audioFrameCount += 1
            audioInput.append(sampleBuffer)
            if audioFrameCount % 100 == 0 {
                print("🎵 Processed audio frame #\(audioFrameCount)")
            }
        }
    }
    
    private func createPixelBuffer(from ciImage: CIImage, with template: CVPixelBuffer) -> CVPixelBuffer? {
        var newPixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,
                           CVPixelBufferGetWidth(template),
                           CVPixelBufferGetHeight(template),
                           CVPixelBufferGetPixelFormatType(template),
                           [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                           &newPixelBuffer)
        
        guard let outputBuffer = newPixelBuffer else { 
            print("⚠️ Failed to create pixel buffer from CI image")
            return nil 
        }
        
        ciContext.render(ciImage, to: outputBuffer)
        return outputBuffer
    }

    // Add helper property for tracking keyframes
    private var lastKeyFrameTime: CMTime?

    // Add helper method for creating sample buffers
    private func createSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        formatDescription: CMFormatDescription,
        timing: UnsafeMutablePointer<CMSampleTimingInfo>
    ) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: timing,
            sampleBufferOut: &sampleBuffer
        )
        
        if status != noErr {
            print("⚠️ Failed to create sample buffer: \(status)")
            return nil
        }
        
        return sampleBuffer
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

extension CameraError {
    static func configurationFailed(message: String = "Camera configuration failed") -> CameraError {
        return .custom(message: message)
    }
}
