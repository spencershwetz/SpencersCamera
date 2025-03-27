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

class CameraViewModel: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
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
            if let settings = try? SettingsModel() {
                if isRecording && settings.isFlashlightEnabled {
                    Task {
                        await flashlightManager.performStartupSequence()
                    }
                } else {
                    flashlightManager.cleanup()
                }
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
    
    private let movieOutput = AVCaptureMovieFileOutput()
    private var currentRecordingURL: URL?
    
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
            case .hevc: return 35_000_000 // 35 Mbps
            case .proRes: return 0 // ProRes doesn't use bitrate control
            }
        }
    }
    
    @Published var selectedCodec: VideoCodec = .hevc {
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
    
    private var orientationMonitorTimer: Timer?
    
    // Temporarily disable the orientation enforcement during recording
    private var isOrientationLocked = false
    
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
        static let enableLowLatency = "EnableLowLatencyRateControl" as CFString
        static let requireHardwareEncoder = "RequireHardwareAcceleratedVideoEncoder" as CFString
        
        // Color space constants for HEVC
        static let colorPrimariesP3D65 = "P3_D65" as CFString
        static let colorPrimariesITUR709 = "ITU_R_709_2" as CFString
        static let transferFunctionHLG = "ITU_R_2100_HLG" as CFString
        static let transferFunctionITUR709 = "ITU_R_709_2" as CFString
        static let yCbCrMatrix2020 = "ITU_R_2020" as CFString
        static let yCbCrMatrixITUR709 = "ITU_R_709_2" as CFString
        
        // VideoToolbox constants
        static let compressionPropertyKeyPriority = "Priority" as CFString
        static let sessionPriorityRealtimePreview = "RealtimePreview" as CFString
    }
    
    private var encoderSpecification: [CFString: Any] {
        [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
    }
    
    override init() {
        // Set default values before super.init()
        super.init()
        print("\n=== Camera Initialization ===")
        
        // Add observer for flashlight settings changes
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .flashlightSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let settings = try? SettingsModel() {
                if self.isRecording && settings.isFlashlightEnabled {
                    self.flashlightManager.isEnabled = true
                    self.flashlightManager.intensity = settings.flashlightIntensity
                } else {
                    self.flashlightManager.isEnabled = false
                }
            }
        }
        
        do {
            // Enable Apple Log by default
            isAppleLogEnabled = true
            selectedCodec = .hevc
            
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
            
            // Configure Apple Log and HEVC encoding
            Task {
                do {
                    try await configureAppleLog()
                    try setupHEVCEncoder()
                } catch {
                    print("Error configuring default settings: \(error)")
                }
            }
        } catch {
            self.error = .setupFailed
            print("Failed to setup session: \(error)")
        }
        
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                guard let self = self,
                      let connection = self.movieOutput.connection(with: .video) else { return }
                self.updateVideoOrientation(connection)
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateShutterAngle(180.0)
        }
        
        print("📱 LUT Loading: No default LUTs will be loaded")
        
        startOrientationMonitoring()
    }
    
    deinit {
        orientationMonitorTimer?.invalidate()
        orientationMonitorTimer = nil
        
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
                
                if let videoConnection = movieOutput.connection(with: .video) {
                    updateVideoOrientation(videoConnection, lockCamera: true)
                }
                
                session.startRunning()
            }
            
            // Check available codecs first
            let availableCodecs = movieOutput.availableVideoCodecTypes
            print("📝 Available codecs: \(availableCodecs)")
            
            // When Apple Log is enabled, we must use ProRes
            await MainActor.run {
                selectedCodec = .proRes
            }
            
            // Find a format that supports Apple Log and ProRes
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
            print("❌ Error configuring Apple Log: \(error.localizedDescription)")
            device.unlockForConfiguration()
            session.commitConfiguration()
            session.startRunning()
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
        
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        
        do {
            session.stopRunning()
            session.beginConfiguration()
            
            try device.lockForConfiguration()
            defer {
                device.unlockForConfiguration()
                session.commitConfiguration()
                
                if let videoConnection = movieOutput.connection(with: .video) {
                    updateVideoOrientation(videoConnection, lockCamera: true)
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
        print("DEBUG: 🎥 Setting up camera session")
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.beginConfiguration()
        
        // Add video data output for HEVC encoding
        let videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput.alwaysDiscardsLateVideoFrames = false
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        videoDataOutput.setSampleBufferDelegate(self, queue: encoderQueue)
        
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            print("DEBUG: ✅ Added video data output for HEVC encoding")
            
            // Configure video data output connection
            if let connection = videoDataOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
                updateVideoOrientation(connection, lockCamera: true)
            }
        }
        
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
            
            if isAppleLogEnabled, let appleLogFormat = findBestAppleLogFormat(videoDevice) {
                let frameRateRange = appleLogFormat.videoSupportedFrameRateRanges.first!
                try videoDevice.lockForConfiguration()
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.maxFrameRate))
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.minFrameRate))
                videoDevice.activeFormat = appleLogFormat
                videoDevice.activeColorSpace = .appleLog
                print("Initial setup: Enabled Apple Log in 4K ProRes format")
                videoDevice.unlockForConfiguration()
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
            
            if session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
                print("DEBUG: ✅ Added movie output to session")
                
                movieOutput.movieFragmentInterval = .invalid
                
                if let connection = movieOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }
                    updateVideoOrientation(connection, lockCamera: true)
                }
            } else {
                print("DEBUG: ❌ Failed to add movie output to session")
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
        
        do {
            // Create temporary URL for recording
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "recording_\(Date().timeIntervalSince1970).mov"
            let tempURL = tempDir.appendingPathComponent(fileName)
            currentRecordingURL = tempURL
            
            // Start recording
            movieOutput.startRecording(to: tempURL, recordingDelegate: self)
            isRecording = true
            print("✅ Started recording to: \(tempURL.path)")
        } catch {
            self.error = .recordingFailed
            print("❌ Failed to start recording: \(error)")
        }
    }
    
    @MainActor
    func stopRecording() async {
        guard isRecording else { return }
        
        movieOutput.stopRecording()
        isRecording = false
        print("🔄 Stopping recording...")
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
    
    private func updateVideoOrientation(_ connection: AVCaptureConnection, lockCamera: Bool = false) {
        let requiredAngles: [CGFloat] = [0, 90, 180, 270]
        let supportsRotation = requiredAngles.allSatisfy { angle in
            connection.isVideoRotationAngleSupported(angle)
        }
        
        guard supportsRotation else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Skip orientation enforcement if video library is presented
            if AppDelegate.isVideoLibraryPresented {
                return
            }
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let interfaceOrientation = windowScene.interfaceOrientation
                self.currentInterfaceOrientation = interfaceOrientation
                
                if !lockCamera {
                    switch interfaceOrientation {
                    case .portrait:
                        connection.videoRotationAngle = 90
                    case .portraitUpsideDown:
                        connection.videoRotationAngle = 270
                    case .landscapeLeft:
                        connection.videoRotationAngle = 0
                    case .landscapeRight:
                        connection.videoRotationAngle = 180
                    default:
                        connection.videoRotationAngle = 90
                    }
                } else {
                    connection.videoRotationAngle = 90
                    print("DEBUG: Camera orientation locked to fixed angle: 90°")
                }
            }
            
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = false
            }
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
    
    func updateInterfaceOrientation(lockCamera: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("DEBUG: Enforcing camera orientation lock...")
            
            // Update current orientation state
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                self.currentInterfaceOrientation = windowScene.interfaceOrientation
                
                // First: Lock movie output connection
                if let connection = self.movieOutput.connection(with: .video) {
                    // Always enforce fixed rotation for video
                    if connection.videoRotationAngle != 90 {
                        connection.videoRotationAngle = 90
                        print("DEBUG: CameraViewModel enforced fixed angle=90° for video connection")
                    }
                    
                    // Check and set any other connections as well
                    self.movieOutput.connections.forEach { conn in
                        if conn !== connection && conn.isVideoRotationAngleSupported(90) && conn.videoRotationAngle != 90 {
                            conn.videoRotationAngle = 90
                            print("DEBUG: Set additional connection to 90°")
                        }
                    }
                }
                
                // Second: Force all session connections to have fixed rotation
                self.session.connections.forEach { connection in
                    if connection.isVideoRotationAngleSupported(90) && connection.videoRotationAngle != 90 {
                        connection.videoRotationAngle = 90
                        print("DEBUG: Set session connection to 90°")
                    }
                }
                
                // Third: Check all session outputs and their connections
                self.session.outputs.forEach { output in
                    output.connections.forEach { connection in
                        if connection.isVideoRotationAngleSupported(90) && connection.videoRotationAngle != 90 {
                            connection.videoRotationAngle = 90
                            print("DEBUG: Set output connection to 90°")
                        }
                    }
                }
            }
        }
    }
    
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
                if let connection = movieOutput.connection(with: .video),
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
    
    private func enforceFixedOrientation() {
        guard isSessionRunning && !isOrientationLocked && !isRecording else { return }
        
        // If video library is presented, we should not enforce orientation
        guard !AppDelegate.isVideoLibraryPresented else {
            print("DEBUG: [ORIENTATION-DEBUG] Skipping camera orientation enforcement since video library is active")
            return
        }
        
        // If video library is not presented, enforce camera orientation
        DispatchQueue.main.async {
            self.movieOutput.connections.forEach { connection in
                if connection.isVideoRotationAngleSupported(90) && connection.videoRotationAngle != 90 {
                    connection.videoRotationAngle = 90
                    print("DEBUG: Timer enforced fixed angle=90° on connection")
                }
            }
            
            self.session.connections.forEach { connection in
                if connection.isVideoRotationAngleSupported(90) && connection.videoRotationAngle != 90 {
                    connection.videoRotationAngle = 90
                }
            }
        }
    }
    
    private func startOrientationMonitoring() {
        // Only start if not already locked
        guard !isOrientationLocked else { return }
        
        orientationMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, !self.isOrientationLocked else { return }
                
                // Skip enforcing orientation if video library is presented
                if !AppDelegate.isVideoLibraryPresented {
                    self.enforceFixedOrientation()
                } else {
                    print("DEBUG: [ORIENTATION-DEBUG] Skipping camera orientation enforcement since video library is active")
                }
            }
        }
        
        print("DEBUG: Started orientation monitoring timer")
    }
    
    func updateOrientation(_ orientation: UIInterfaceOrientation) {
        self.currentInterfaceOrientation = orientation
        updateInterfaceOrientation()
    }
    
    private func updateVideoConfiguration() {
        print("\n=== Updating Video Configuration ===")
        print("🎬 Selected Codec: \(selectedCodec.rawValue)")
        print("🎨 Apple Log Enabled: \(isAppleLogEnabled)")
        
        guard let device = device,
              let connection = movieOutput.connection(with: .video) else {
            print("❌ No video connection available")
            return
        }
        
        // Check available codecs
        let availableCodecs = movieOutput.availableVideoCodecTypes
        print("📝 Available codecs: \(availableCodecs)")
        
        // First, ensure we're in the right format for the selected codec
        do {
            try device.lockForConfiguration()
            
            // Find a suitable format that supports our requirements
            let formats = device.formats.filter { format in
                let desc = format.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                let matchesResolution = dimensions.width >= selectedResolution.dimensions.width &&
                                      dimensions.height >= selectedResolution.dimensions.height
                let hasAppleLog = isAppleLogEnabled ? format.supportedColorSpaces.contains(.appleLog) : true
                
                return matchesResolution && hasAppleLog
            }
            
            if let selectedFormat = formats.first {
                device.activeFormat = selectedFormat
                
                // Set frame rate
                let duration = CMTimeMake(value: 1000, timescale: Int32(selectedFrameRate * 1000))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                
                // Set color space
                device.activeColorSpace = isAppleLogEnabled ? .appleLog : .sRGB
                
                print("✅ Set appropriate format for \(isAppleLogEnabled ? "Apple Log" : "Rec.709") recording")
            } else {
                print("❌ No suitable format found")
                device.unlockForConfiguration()
                return
            }
            
            device.unlockForConfiguration()
        } catch {
            print("❌ Error configuring device: \(error)")
            return
        }
        
        // When Apple Log is enabled, we must record in ProRes
        let proResVariants: [AVVideoCodecType] = [
            AVVideoCodecType(rawValue: "apch"), // ProRes 422 HQ
            AVVideoCodecType(rawValue: "apcn"), // ProRes 422
            AVVideoCodecType(rawValue: "apcs"), // ProRes 422 LT
            AVVideoCodecType(rawValue: "apco")  // ProRes 422 Proxy
        ]
        
        if let bestProRes = proResVariants.first(where: { availableCodecs.contains($0) }) {
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: bestProRes,
                AVVideoCompressionPropertiesKey: [
                    AVVideoExpectedSourceFrameRateKey: NSNumber(value: selectedFrameRate)
                ]
            ]
            
            do {
                movieOutput.setOutputSettings(videoSettings, for: connection)
                print("✅ Configured ProRes recording for Apple Log")
                print("📊 Using codec: \(bestProRes)")
                
                // Set up HEVC hardware encoder for real-time encoding if needed
                if selectedCodec == .hevc {
                    try setupHEVCEncoder()
                }
            } catch {
                print("❌ Failed to set ProRes settings: \(error)")
            }
        }
        
        print("=== End Video Configuration ===\n")
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
        
        // Get the supported frame rate range for this format
        let frameRateRange = selectedFormat.videoSupportedFrameRateRanges.first
        let adjustedFrameRate = frameRateRange.map { range in
            min(max(selectedFrameRate, range.minFrameRate), range.maxFrameRate)
        } ?? 30.0
        
        print("⚙️ Selected Format: \(CMFormatDescriptionGetMediaSubType(selectedFormat.formatDescription))")
        print("⏱️ Adjusted Frame Rate: \(adjustedFrameRate)")
        
        // Begin configuration
        session.beginConfiguration()
        
        do {
            try await device.lockForConfiguration()
            
            // Set the format
            device.activeFormat = selectedFormat
            
            // Set the frame duration
            let duration = CMTime(value: 1, timescale: CMTimeScale(adjustedFrameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            
            // Update the frame rate if it was adjusted
            if adjustedFrameRate != selectedFrameRate {
                await MainActor.run {
                    selectedFrameRate = adjustedFrameRate
                }
            }
            
            // Update video configuration
            updateVideoConfiguration()
            
            device.unlockForConfiguration()
            
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
            // Ensure we clean up in case of error
            device.unlockForConfiguration()
            session.commitConfiguration()
            
            // Restore session state if it was running
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
                if let connection = movieOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }
                    updateVideoOrientation(connection, lockCamera: true)
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
        print("🎥 Current recording state:")
        print("- Apple Log: \(isAppleLogEnabled)")
        print("- Selected Codec: \(selectedCodec.rawValue)")
        print("- Frame Rate: \(selectedFrameRate)")
        
        // Clean up any existing session
        if let session = compressionSession {
            print("🧹 Cleaning up existing compression session")
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        
        // Get dimensions from the active format
        guard let device = device,
              let dimensions = device.activeFormat.dimensions else {
            print("❌ Failed to get device dimensions")
            throw CameraError.configurationFailed
        }
        
        print("📐 Encoding dimensions: \(dimensions.width)x\(dimensions.height)")
        
        // Enhanced encoder specification for real-time encoding
        let enhancedEncoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 1,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1
        ]
        
        print("⚙️ Creating compression session with hardware acceleration")
        
        // Create compression session with hardware acceleration
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(dimensions.width),
            height: Int32(dimensions.height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: enhancedEncoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { outputCallbackRefCon, sourceFrameRefCon, status, flags, sampleBuffer in
                guard let sampleBuffer = sampleBuffer else { return }
                
                // Create a unique filename for each encoded frame
                let tempDir = FileManager.default.temporaryDirectory
                let fileName = "encoded_frame_\(Date().timeIntervalSince1970).hevc"
                let fileURL = tempDir.appendingPathComponent(fileName)
                
                // Write the encoded frame to disk
                if let data = sampleBuffer.dataBuffer {
                    var totalLength: Int = 0
                    var dataPointer: UnsafeMutablePointer<Int8>?
                    CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil, 
                                              totalLengthOut: &totalLength, 
                                              dataPointerOut: &dataPointer)
                    if let pointer = dataPointer {
                        let bufferData = Data(bytes: pointer, count: totalLength)
                        try? bufferData.write(to: fileURL)
                        print("✅ Wrote encoded frame to: \(fileURL.path)")
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
        
        // Configure encoder properties optimized for real-time HEVC encoding
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_ProfileLevel: isAppleLogEnabled ? 
                kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 1,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: isAppleLogEnabled ? 50_000_000 : 35_000_000,
            kVTCompressionPropertyKey_DataRateLimits: [50_000_000, 1] as [NSNumber],
            kVTCompressionPropertyKey_ExpectedFrameRate: Float64(selectedFrameRate),
            kVTCompressionPropertyKey_RealTime: true,
            VTConstants.compressionPropertyKeyPriority: VTConstants.sessionPriorityRealtimePreview,
            kVTCompressionPropertyKey_ColorPrimaries: isAppleLogEnabled ? 
                VTConstants.colorPrimariesP3D65 : VTConstants.colorPrimariesITUR709,
            kVTCompressionPropertyKey_TransferFunction: isAppleLogEnabled ? 
                VTConstants.transferFunctionHLG : VTConstants.transferFunctionITUR709,
            kVTCompressionPropertyKey_YCbCrMatrix: isAppleLogEnabled ? 
                VTConstants.yCbCrMatrix2020 : VTConstants.yCbCrMatrixITUR709,
            kVTCompressionPropertyKey_HDRMetadataInsertionMode: isAppleLogEnabled ? 
                kVTHDRMetadataInsertionMode_Auto : kVTHDRMetadataInsertionMode_None
        ]
        
        // Apply properties
        for (key, value) in properties {
            let propStatus = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if propStatus != noErr {
                print("⚠️ Failed to set property \(key.string): \(propStatus)")
            }
        }
        
        // Prepare to encode frames
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepareStatus != noErr {
            print("⚠️ Failed to prepare encoder: \(prepareStatus)")
            throw CameraError.configurationFailed
        }
        
        // Store the session
        compressionSession = session
        print("✅ HEVC Hardware encoder setup complete")
        print("📊 Configuration:")
        print("- Resolution: \(dimensions.width)x\(dimensions.height)")
        print("- Frame Rate: \(selectedFrameRate) fps")
        print("- Bitrate: \(properties[kVTCompressionPropertyKey_AverageBitRate] as! Int / 1_000_000) Mbps")
        print("- Color Space: \(isAppleLogEnabled ? "Apple Log/HLG" : "Rec.709")")
        print("- Profile: \(isAppleLogEnabled ? "HEVC Main 10" : "HEVC Main")")
        print("- Hardware Accelerated: Yes")
        print("- Low Latency Mode: Enabled")
        print("=== End HEVC Encoder Setup ===\n")
    }

    // Update AVCaptureVideoDataOutputSampleBufferDelegate to use hardware encoding
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        
        // Always update preview layer if needed
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Process frame for preview if needed
            if let processedImage = processVideoFrame(sampleBuffer) {
                DispatchQueue.main.async { [weak self] in
                    // Notify preview layer to update
                    NotificationCenter.default.post(name: .init("PreviewFrameUpdated"), 
                                                 object: processedImage)
                }
            }
        }
        
        // Handle HEVC encoding if needed
        guard isRecording,
              selectedCodec == .hevc,
              isAppleLogEnabled else {
            return
        }
        
        // Process frame on encoder queue
        encoderQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if we have a valid compression session
            guard let compressionSession = self.compressionSession else {
                print("⚠️ No valid compression session available")
                return
            }
            
            self.encodeFrame(sampleBuffer)
        }
    }
    
    private func encodeFrame(_ sampleBuffer: CMSampleBuffer) {
        print("🎬 Starting HEVC frame encoding")
        
        guard let compressionSession = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            print("❌ Failed to get required properties for encoding")
            return
        }
        
        // Get frame timing info
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
        
        print("⏱️ Frame timing - PTS: \(timing.presentationTimeStamp.seconds), Duration: \(timing.duration.seconds)")
        
        // Create properties for encoding
        var frameProperties: [String: Any] = [
            kVTEncodeFrameOptionKey_ForceKeyFrame as String: true
        ]
        
        // Handle Apple Log metadata if enabled
        if isAppleLogEnabled {
            print("🎨 Adding HDR metadata for Apple Log")
            
            // Add HDR metadata for Apple Log
            frameProperties[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = 
                kVTHDRMetadataInsertionMode_Auto
            
            // Set color tags for Apple Log
            frameProperties[kCVImageBufferColorPrimariesKey as String] = 
                AVVideoColorPrimaries_ITU_R_2020
            frameProperties[kCVImageBufferTransferFunctionKey as String] = 
                AVVideoTransferFunction_ITU_R_2100_HLG
            frameProperties[kCVImageBufferYCbCrMatrixKey as String] = 
                AVVideoYCbCrMatrix_ITU_R_2020
        }
        
        // Encode the frame with hardware acceleration
        print("🔄 Encoding frame with hardware acceleration")
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: timing.presentationTimeStamp,
            duration: timing.duration,
            frameProperties: frameProperties as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        
        if status == noErr {
            print("✅ Frame encoded successfully")
        } else {
            print("⚠️ Failed to encode frame: \(status)")
            
            // Log detailed error for debugging
            switch status {
            case kVTParameterErr:
                print("⚠️ Invalid parameter was specified")
            case kVTInvalidSessionErr:
                print("⚠️ Invalid compression session")
            case kVTAllocationFailedErr:
                print("⚠️ Memory allocation failed")
            case kVTPixelTransferNotSupportedErr:
                print("⚠️ Pixel transfer not supported")
            case kVTCouldNotCreateInstanceErr:
                print("⚠️ Could not create encoder instance")
            default:
                print("⚠️ Unknown error: \(status)")
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        print("Recording started successfully")
        
        // Ensure connections maintain their orientation settings throughout recording
        for connection in connections {
            // Check if this is a video connection
            if connection.inputPorts.contains(where: { $0.mediaType == .video }) {
                print("DEBUG: Recording connection rotation angle: \(connection.videoRotationAngle)°")
                
                // Update the video orientation based on the interface orientation
                let requiredAngles: [CGFloat] = [0, 90, 180, 270]
                let supportsRotation = requiredAngles.allSatisfy { angle in
                    connection.isVideoRotationAngleSupported(angle)
                }
                
                if supportsRotation {
                    // Set rotation angle based on current interface orientation
                    switch currentInterfaceOrientation {
                    case .portrait:
                        connection.videoRotationAngle = 90
                    case .portraitUpsideDown:
                        connection.videoRotationAngle = 270
                    case .landscapeLeft:
                        connection.videoRotationAngle = 0
                    case .landscapeRight:
                        connection.videoRotationAngle = 180
                    default:
                        connection.videoRotationAngle = 90
                    }
                    print("DEBUG: Set recording connection rotation angle to: \(connection.videoRotationAngle)°")
                }
            }
        }
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
