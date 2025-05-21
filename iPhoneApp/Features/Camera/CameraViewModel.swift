import AVFoundation
import SwiftUI
import Photos
import VideoToolbox
import CoreVideo
import os.log
import CoreImage
import CoreMedia
import WatchConnectivity
import Combine

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
    
    // Add volume button handler
    private var volumeButtonHandler: VolumeButtonHandler?
    
    // Combine cancellables
    var cancellables = Set<AnyCancellable>()
    
    // Flashlight manager
    private let flashlightManager = FlashlightManager()
    private var settingsObserver: NSObjectProtocol?
    private var settingsModel: SettingsModel
    
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
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraViewModel")
    
    @Published var isSessionRunning = false
    @Published var error: CameraError?
    @Published var whiteBalance: Float = 5000 // Kelvin
    @Published var iso: Float = 100
    @Published var shutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 60)
    @Published var isRecording = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)
            
            // Handle flashlight state based on recording state
            if isRecording && settingsModel.isFlashlightEnabled {
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
    
    // Exposure Lock
    @Published var isExposureLocked: Bool = false {
        didSet {
            updateExposureLock() 
        }
    }
    @Published var isShutterPriorityEnabled: Bool = false
    
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
    
    @Published var isAppleLogEnabled: Bool { // Property will be bound to settingsModel
        didSet {
            // Update settingsModel value
            settingsModel.isAppleLogEnabled = isAppleLogEnabled
            
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
            
            // Capture necessary values before the Task
            let logEnabled = self.isAppleLogEnabled
            let currentLensVal = self.currentLens.rawValue
            let formatService = self.videoFormatService // Assume services are Sendable or actors
            let deviceService = self.cameraDeviceService // Assume services are Sendable or actors
            let logger = self.logger // Logger is Sendable

            Task {
                logger.info("🚀 Starting Task to configure Apple Log to \(logEnabled) for lens: \(currentLensVal)x")
                do {
                    // Update the service state first
                    formatService?.setAppleLogEnabled(logEnabled) // Use captured value
                    
                    // Asynchronously configure the format
                    if logEnabled {
                        logger.info("🎥 Calling videoFormatService.configureAppleLog() to prepare device...")
                        guard let formatService = formatService else { throw CameraError.setupFailed }
                        try await formatService.configureAppleLog() // Use captured service
                        logger.info("✅ Successfully completed configureAppleLog() device preparation.")
                    } else {
                        logger.info("🎥 Calling videoFormatService.resetAppleLog() to prepare device...")
                        guard let formatService = formatService else { throw CameraError.setupFailed }
                        try await formatService.resetAppleLog() // Use captured service
                        logger.info("✅ Successfully completed resetAppleLog() device preparation.")
                    }
                    
                    // Step 2: Trigger CameraDeviceService to reconfigure the session with the prepared device state
                    logger.info("🔄 Calling cameraDeviceService.reconfigureSessionForCurrentDevice() to apply changes...")
                    guard let deviceService = deviceService else { throw CameraError.setupFailed }
                    try await deviceService.reconfigureSessionForCurrentDevice() // Use captured service
                    logger.info("✅ Successfully completed reconfigureSessionForCurrentDevice().")

                    logger.info("🏁 Finished Task for Apple Log configuration (enabled: \(logEnabled)) successfully.")
                } catch let error as CameraError {
                    logger.error("❌ Task failed during Apple Log configuration/reconfiguration: \(error.description)")
                    // Update error on main thread
                    Task { @MainActor in
                        self.error = error
                    }
                } catch {
                    logger.error("❌ Task failed during Apple Log configuration/reconfiguration with unknown error: \(error.localizedDescription)")
                    let wrappedError = CameraError.configurationFailed(message: "Apple Log setup failed: \(error.localizedDescription)")
                    // Update error on main thread
                    Task { @MainActor in
                        self.error = wrappedError
                    }
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
    private var recordingStartTime: Date?
    
    private var defaultFormat: AVCaptureDevice.Format?
    
    var minISO: Float {
        device?.activeFormat.minISO ?? 50
    }
    var maxISO: Float {
        device?.activeFormat.maxISO ?? 1600
    }
    
    @Published var selectedFrameRate: Double = 30.0 {
        didSet {
            // Update settingsModel value
            settingsModel.selectedFrameRate = selectedFrameRate
            
            if isShutterPriorityEnabled {
                logger.info("Frame rate changed to \(self.selectedFrameRate) while Shutter Priority is active. Re-applying 180° shutter.")
                updateShutterAngle(180.0)
            }
        }
    }
    let availableFrameRates: [Double] = [23.976, 24.0, 25.0, 29.97, 30.0]
    
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
        
        static var defaultRes: Resolution {
            return .uhd
        }
    }
    
    @Published var selectedResolution: Resolution = .uhd {
        didSet {
            // Update settingsModel value
            settingsModel.selectedResolutionRaw = selectedResolution.rawValue
            
            Task {
                do {
                    try await videoFormatService.updateCameraFormat(for: selectedResolution)
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
        
        static var defaultCodec: VideoCodec {
            return .hevc
        }
    }
    
    @Published var selectedCodec: VideoCodec = .hevc {
        didSet {
            // Update settingsModel value
            settingsModel.selectedCodecRaw = selectedCodec.rawValue
            
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
    
    @Published var currentTint: Float = 0 // Change type to Float
    let tintRange: ClosedRange<Float> = -150.0...150.0
    
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    @Published var isAutoExposureEnabled: Bool = true {
        didSet {
            exposureService.setAutoExposureEnabled(isAutoExposureEnabled)
        }
    }
    
    @Published var lutManager = LUTManager()
    // let lutProcessor = LUTProcessor() // REMOVED old CI processor instance
    let metalFrameProcessor = MetalFrameProcessor() // ADDED Metal processor instance
    
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
    
    // Store exposure lock state before recording starts if auto-lock is enabled
    private var previousExposureMode: AVCaptureDevice.ExposureMode? // Store actual mode
    private var previousISO: Float? // Store ISO if mode was .custom
    private var previousExposureDuration: CMTime? // Store duration if mode was .custom
    
    // Service Instances
    private var cameraSetupService: CameraSetupService!
    private var exposureService: ExposureService!
    private var recordingService: RecordingService!
    internal var cameraDeviceService: CameraDeviceService!
    private var videoFormatService: VideoFormatService!
    
    @Published var lastLensSwitchTimestamp = Date()
    @Published var exposureBias: Float = 0.0
    private var lastExposureBias: Float = 0.0  // Store last EV bias value
    var minExposureBias: Float { device?.minExposureTargetBias ?? -2.0 }
    var maxExposureBias: Float { device?.maxExposureTargetBias ?? 2.0 }
    
    // Logger for orientation specific logs
    private let orientationLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraViewModelOrientation")
    
    // Watch Connectivity properties
    private var wcSession: WCSession?
    private let wcLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "WatchConnectivity")
    private var isAppCurrentlyActive = false // Track app active state
    
    // Timer for polling WB
    private var wbPollingTimerCancellable: AnyCancellable?
    private let wbPollingInterval: TimeInterval = 0.5 // Poll every 0.5 seconds

    // --- Shutter Priority Debounce State ---
    private var shutterPriorityReapplyTask: Task<Void, Never>? = nil
    private var lastSPISO: Float? = nil // Cache last ISO for SP

    @Published var isExposureUIFrozen: Bool = false // NEW: Freeze UI during lens switch/SP re-apply

    @Published var isWhiteBalanceAuto: Bool = true

    // Flag to prevent session/camera/color space reconfiguration during LUT removal
    private var isLUTBeingRemoved = false

    enum ExposureMode: String, Codable, Equatable {
        case auto
        case manual
        case shutterPriority
        case locked
    }

    @Published var currentExposureMode: ExposureMode = .auto

    // MARK: - Public Exposure Bias Setter
    func setExposureBias(_ bias: Float) {
        exposureService.updateExposureTargetBias(bias)
    }
    
    // Add a computed property to expose the current device for debug purposes
    var currentCameraDevice: AVCaptureDevice? {
        return device
    }
    
    // Add a dedicated queue for session operations
    private let sessionQueue = DispatchQueue(label: "com.camera.sessionQueue", qos: .userInitiated)
    
    // Unified video output
    private let processingQueue = DispatchQueue(label: "com.spencerscamera.processing", qos: .userInteractive)
    private var unifiedVideoOutput: AVCaptureVideoDataOutput?
    var metalPreviewDelegate: MetalPreviewView?
    
    let locationService = LocationService.shared
    
    private var lastKnownGoodState: ExposureState?
    
    init(settingsModel: SettingsModel = SettingsModel()) {
        self.settingsModel = settingsModel
        // Initialize properties that need a value before super
        
        // Set selected resolution from settings
        isAppleLogEnabled = settingsModel.isAppleLogEnabled
        selectedCodec = settingsModel.selectedCodec
        selectedResolution = settingsModel.selectedResolution
        selectedFrameRate = settingsModel.selectedFrameRate
        
        super.init()
        setupServices()
        
        // Configure WCSession if available
        setupWatchConnectivity()
        
        // Setup observers
        settingsObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("LUTBakeInChanged"), object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            let isBakeInEnabled = self.settingsModel.isBakeInLUTEnabled
            self.logger.info("LUT Bake-In setting changed to \(isBakeInEnabled)")
            self.recordingService?.setBakeInLUTEnabled(isBakeInEnabled)
        }
        
        // Add observer for memory cleanup notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryCleanupRequest),
            name: NSNotification.Name("TriggerMemoryCleanup"),
            object: nil
        )
    }

    // Add handler for memory cleanup
    @objc private func handleMemoryCleanupRequest() {
        logger.info("Memory cleanup requested")
        
        // Clear any unnecessary cached data
        autoreleasepool {
            // Release Metal textures if needed
            if lutManager.currentLUTTexture != nil && !isRecording {
                // Temporarily clear LUT texture if we're not recording
                // This will be restored when needed
                tempLUTFilter = lutManager.currentLUTFilter
                isLUTBeingRemoved = true
                lutManager.clearCurrentLUT()
                isLUTBeingRemoved = false
                
                // Schedule restoration after a short delay if needed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { return }
                    if self.tempLUTFilter != nil {
                        self.tempLUTFilter = nil
                        // Only restore if we're not in the middle of another operation
                        if !self.isRecording && !self.isProcessingRecording {
                            // Restore LUT from the saved filter
                            if let lutURL = self.lutManager.selectedLUTURL {
                                self.lutManager.loadLUT(from: lutURL)
                            }
                        }
                    }
                }
            }
            
            // Force a garbage collection cycle
            logger.info("Memory cleanup completed")
        }
    }
    
    deinit {
        logger.info("[LIFECYCLE] CameraViewModel DEINIT")
        // Remove all notification observers FIRST
        NotificationCenter.default.removeObserver(self)

        // Explicitly remove device observers BEFORE stopping the session
        // This ensures observers are gone while exposureService is still valid.
        exposureService.removeDeviceObservers()
        logger.info("Explicitly removed ExposureService KVO observers in CameraViewModel deinit")

        // Nil out delegates for AVCaptureOutputs to break potential retain cycles
        if let videoOutput = self.unifiedVideoOutput {
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            logger.info("[LIFECYCLE] Nilled delegate for unifiedVideoOutput in deinit.")
        }
        // Assuming 'audioDataOutput' is the AVCaptureAudioDataOutput instance CameraViewModel itself might be a delegate for.
        // If CameraViewModel doesn't actually create/manage its own audioDataOutput distinct from RecordingService's,
        // this line might target a nil object or a misattributed one. Based on delegate conformance, it should have one.
        if let audioOutput = self.audioDataOutput { // audioDataOutput is a property of CameraViewModel
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            logger.info("[LIFECYCLE] Nilled delegate for CameraViewModel's audioDataOutput in deinit.")
        }

        // Ensure the session is stopped if running
        if session.isRunning {
            logger.info("Stopping session in deinit (asynchronously)")
            // Use sync on sessionQueue IF deinit isn't already on it, otherwise deadlock risk.
            // Let's stick to async but acknowledge the timing risk.
            sessionQueue.async { [weak self] in // Use sessionQueue
                // Check session again inside async block as state might change
                if self?.session.isRunning ?? false {
                     self?.session.stopRunning()
                     self?.logger.info("Session stopped asynchronously in deinit on sessionQueue")
                } else {
                     self?.logger.info("Session was already stopped before async block executed in deinit.")
                }
            }
        } else {
             logger.info("Session was not running at the start of deinit.")
        }

        // Deactivate WCSession delegate if needed
        if WCSession.isSupported() {
            WCSession.default.delegate = nil // Clear delegate
            logger.info("Cleared WCSession delegate in deinit")
        }
        
        logger.info("CameraViewModel deinitialization sequence complete.") // Added final log
    }
    
    private func setupServices() {
        // Initialize services with self as delegate
        // Ensure ExposureService is initialized before CameraSetupService
        exposureService = ExposureService(delegate: self)
        // Inject closure to allow ExposureService to check stabilization state
        exposureService.isVideoStabilizationCurrentlyEnabled = { [weak self] in
            return self?.settingsModel.isVideoStabilizationEnabled ?? false
        }
        
        // Initialize video format service early as it's needed by other services
        videoFormatService = VideoFormatService(session: session, delegate: self)
        
        // Initialize recording service
        recordingService = RecordingService(session: session, delegate: self)
        recordingService.setMetalFrameProcessor(self.metalFrameProcessor)
        
        // Pass exposureService to CameraDeviceService initializer
        cameraDeviceService = CameraDeviceService(session: session, videoFormatService: videoFormatService, exposureService: exposureService, delegate: self)
        
        // Initialize CameraSetupService last, after all dependencies are ready
        cameraSetupService = CameraSetupService(session: session, exposureService: exposureService, delegate: self, viewModel: self)
        
        // Set up notification observers
        setupSettingObservers()
        
        // Configure session asynchronously to not block initialization
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // Prevent session/camera/color space reconfiguration if LUT is being removed
            if self.isLUTBeingRemoved { return }
            do {
                try self.cameraSetupService.setupSession()
                self.logger.info("Camera session setup completed successfully")
                // --- Ensure color space is set to user preference on initial boot ---
                // NOTE: LUT loading is always decoupled from color space configuration.
                //       Loading a LUT (even one named 'Apple Log to Rec709') will never change the camera's color space.
                //       Only the user's Apple Log toggle controls the color space.
                Task {
                    do {
                        if self.isAppleLogEnabled && self.isAppleLogSupported {
                            self.logger.info("[Boot] Applying Apple Log color space after initial session setup...")
                            try await self.videoFormatService.configureAppleLog()
                        } else {
                            self.logger.info("[Boot] Applying Rec. 709 / P3 color space after initial session setup...")
                            try await self.videoFormatService.resetAppleLog()
                        }
                        self.logger.info("[Boot] Successfully applied color space after initial session setup.")
                    } catch {
                        self.logger.error("[Boot] Failed to apply color space after initial session setup: \(error)")
                    }
                }
                // --- END color space boot logic ---
            } catch {
                self.logger.error("Failed to setup camera session: \(error)")
                DispatchQueue.main.async {
                    self.error = error as? CameraError ?? .setupFailed
                    self.status = .failed
                }
            }
        }
    }
    
    func updateWhiteBalance(_ temperature: Float) {
        isWhiteBalanceAuto = false // Switching to manual WB
        exposureService.updateWhiteBalance(temperature)
    }

    /// Enables or disables automatic white-balance.
    func setWhiteBalanceAuto(_ enabled: Bool) {
        isWhiteBalanceAuto = enabled
        exposureService.setAutoWhiteBalanceEnabled(enabled)
    }
    
    func updateISO(_ isoValue: Float) {
        // If auto exposure is on, trying to set ISO manually should turn it off.
        if self.isAutoExposureEnabled {
            self.isAutoExposureEnabled = false
            logger.info("ISO updated manually, disabling isAutoExposureEnabled.")
        }
        exposureService.updateISO(isoValue)
    }
    
    func updateShutterSpeed(_ speed: CMTime) {
        exposureService.updateShutterSpeed(speed)
    }
    
    func updateShutterAngle(_ angle: Double) {
        exposureService.updateShutterAngle(angle, frameRate: selectedFrameRate)
    }
    
    func updateFrameRate(_ fps: Double) {
        do {
            try videoFormatService.updateFrameRate(fps)
        } catch {
            print("❌ Frame rate error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    func updateTint(_ newValue: Double) {
        // Cast the incoming Double to Float before clamping and setting
        let floatValue = Float(newValue)
        currentTint = floatValue.clamped(to: tintRange)
        exposureService.updateTint(currentTint, currentWhiteBalance: whiteBalance)
    }
    
    func switchToLens(_ lens: CameraLens) {
        // Remove video output delegate before switching
        unifiedVideoOutput?.setSampleBufferDelegate(nil, queue: nil)
        
        // Store current EV bias before lens switch
        lastExposureBias = exposureBias
        
        // Track shutter priority state
        let wasShutterPriorityEnabled = isShutterPriorityEnabled
        
        // --- LUT Restoration Fix ---
        // Persist the last selected LUT URL before clearing
        let lastLUTURL = lutManager.selectedLUTURL
        // --- END LUT Restoration Fix ---
        
        // Explicitly release memory before lens switch
        autoreleasepool {
            // Temporarily disable LUT preview during switch to prevent flash and reduce memory usage
            logger.debug("🔄 Lens switch: Temporarily disabling LUT filter.")
            self.tempLUTFilter = lutManager.currentLUTFilter // Store current filter
            lutManager.clearCurrentLUT() // Clear both texture and filter to reduce memory usage
            
            // Force a memory cleanup cycle for Metal resources
            if let textureCache = metalFrameProcessor?.textureCache {
                CVMetalTextureCacheFlush(textureCache, 0)
                logger.debug("🔄 Lens switch: Flushed Metal texture cache before switch.")
            }
            
            // Force a GC cycle
            logger.debug("🔄 Lens switch: Running memory cleanup before switch.")
        }
        
        // Perform the lens switch
        videoFormatService.setAppleLogEnabled(isAppleLogEnabled)
        cameraDeviceService.switchToLens(lens)
        
        // Update the timestamp immediately to trigger orientation update in PreviewView via updateState
        lastLensSwitchTimestamp = Date()
        logger.debug("🔄 Lens switch: Updated lastLensSwitchTimestamp to trigger PreviewView orientation update.")

        // --- LUT Restoration Fix ---
        // Schedule LUT restoration after a short delay to ensure smooth lens transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            // Restore LUT filter if one was stored or if a LUT was loaded before
            if let lutURL = lastLUTURL {
                self.logger.debug("🔄 Lens switch: Re-enabling LUT from last selected URL after delay.")
                self.lutManager.loadLUT(from: lutURL)
                self.tempLUTFilter = nil
            } else if self.tempLUTFilter != nil {
                self.logger.debug("🔄 Lens switch: Re-enabling stored LUT filter after delay (no URL, fallback).")
                if let lutURL = self.lutManager.selectedLUTURL {
                    self.lutManager.loadLUT(from: lutURL)
                }
                self.tempLUTFilter = nil
            }
        }
        // --- END LUT Restoration Fix ---
        
        // After a short delay to ensure the device is ready, restore settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            
            // Restore EV bias first
            if self.lastExposureBias != 0.0 {
                self.logger.info("🔄 Restoring EV bias after lens switch: \(self.lastExposureBias)")
                self.setExposureBias(self.lastExposureBias)
            }
            
            // Re-apply shutter priority if it was active
            if wasShutterPriorityEnabled {
                self.logger.info("🔄 [switchToLens] Re-applying shutter priority after lens switch")
                self.ensureShutterPriorityConsistency()
            }
        }
        
        // Re-attach video output delegate after session is running
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if let videoOutput = self.unifiedVideoOutput {
                let highPriorityQueue = DispatchQueue(label: "com.camera.preview", qos: .userInteractive, attributes: .concurrent)
                videoOutput.setSampleBufferDelegate(self, queue: highPriorityQueue)
            }
        }
    }
    
    func setZoomFactor(_ factor: CGFloat) {
        // Remove isRecording argument
        cameraDeviceService.setZoomFactor(factor, currentLens: currentLens, availableLenses: availableLenses)
    }
    
    @MainActor
    func startRecording() async {
        guard !isRecording else {
            logger.warning("Start recording called but already recording.")
            return
        }

        guard let currentDevice = self.device else {
            logger.error("Cannot start recording: No camera device available.")
            self.error = .cameraUnavailable
            return
        }

        logger.info("Requesting recording start.")

        // Handle auto-locking exposure if enabled
        if self.settingsModel.isExposureLockEnabledDuringRecording {
            // --- Modification Start ---
            // Store the actual current mode before applying any lock
            previousExposureMode = currentDevice.exposureMode
            if previousExposureMode == .custom {
                previousISO = currentDevice.iso
                previousExposureDuration = currentDevice.exposureDuration
            }
            logger.info("Storing previous exposure state: Mode \\(String(describing: previousExposureMode))")
            
            if isShutterPriorityEnabled {
                // Shutter Priority Lock (SP is ON)
                logger.info("SP active and lock enabled: Locking Shutter Priority exposure for recording.")
                exposureService.lockShutterPriorityExposureForRecording() // Use new service method
                // No need to store ISO/Duration here anymore, service handles it
            } else {
                // Standard AE Lock (SP is OFF)
                logger.info("Standard AE lock enabled: Locking exposure for recording.")
                exposureService.setExposureLock(locked: true)
                self.isExposureLocked = true // Update UI for standard lock
            }
            // --- Modification End ---
        }

        // Lock white balance if enabled in settings
        if self.settingsModel.isWhiteBalanceLockEnabled {
            logger.info("Auto-locking white balance for recording start.")
            exposureService.updateWhiteBalance(self.whiteBalance)
        }

        // Set the selected LUT TEXTURE onto the METAL processor BEFORE configuring the recording service
        logger.debug("Setting Metal LUT texture for bake-in: \(self.lutManager.currentLUTTexture != nil ? "Available" : "None")")
        recordingService.setLUTTextureForBakeIn(lutManager.currentLUTTexture) // <-- Use new method to set texture

        // Update configuration for recording
        recordingService.setDevice(currentDevice)
        recordingService.setAppleLogEnabled(isAppleLogEnabled)
        recordingService.setBakeInLUTEnabled(self.settingsModel.isBakeInLUTEnabled)

        // ---> ADD LOGGING HERE <---
        logger.info("DEBUG_FRAMERATE: Configuring RecordingService with selectedFrameRate: \\(self.selectedFrameRate)")
        // ---> END LOGGING <---

        recordingService.setVideoConfiguration(
            frameRate: selectedFrameRate,
            resolution: selectedResolution,
            codec: selectedCodec
        )
        
        // Get current orientation angle for recording
        let connectionAngle = session.outputs.compactMap { $0.connection(with: .video) }.first?.videoRotationAngle ?? -1 // Use -1 to indicate not found
        logger.info("Requesting recording start. Current primary video connection angle: \\(connectionAngle)° (This is passed but ignored by RecordingService)")

        // Inform the RecordingService about the Apple Log state *before* starting
        recordingService?.setAppleLogEnabled(isAppleLogEnabled)
        
        // Explicitly set the Bake-in LUT state *before* starting recording
        recordingService?.setBakeInLUTEnabled(self.settingsModel.isBakeInLUTEnabled)
        
        // Begin location updates for GPS tagging
        locationService.startUpdating()
        
        // START RECORDING
        await recordingService?.startRecording(orientation: connectionAngle) // Pass angle, though it's recalculated inside

        // Set state AFTER recording service confirms start (ideally service would return success/time)
        // For now, assume immediate start for simplicity
        self.recordingStartTime = Date() // Store start Date
        self.isRecording = true
        logger.info("Recording state set to true.")
        
        // Notify RotationLockedContainer about recording state change
        NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)
        
        // Update watch state
        sendStateToWatch()
    }
    
    @MainActor
    func stopRecording() async {
        guard isRecording else {
            logger.warning("Stop recording called but not currently recording.")
            return
        }

        logger.info("Requesting recording stop.")
        // Stop recording
        await recordingService.stopRecording()

        self.isRecording = false
        self.recordingStartTime = nil // Clear start time
        logger.info("Recording state set to false.")

        // Explicitly trigger memory cleanup after recording stops
        autoreleasepool {
            // Force immediate cleanup of any temporary resources used during recording
            logger.info("Performing memory cleanup after recording stopped")
            
            // Flush texture cache to release Metal textures
            if let textureCache = metalFrameProcessor?.textureCache {
                CVMetalTextureCacheFlush(textureCache, 0)
                logger.debug("Flushed Metal texture cache after recording")
            }
            
            // Explicitly notify the GPU to complete any pending work
            if metalFrameProcessor?.textureCache != nil {
                // Wait for any pending GPU work to complete
                logger.debug("Ensuring GPU work is completed")
            }
            
            // Release any strong references to large objects
            if let thumbnail = self.lastRecordedVideoThumbnail, 
               thumbnail.size.width > 200 || thumbnail.size.height > 200 {
                // If thumbnail is larger than needed, downsize it
                let size = CGSize(width: 200, height: 200 * thumbnail.size.height / thumbnail.size.width)
                UIGraphicsBeginImageContextWithOptions(size, false, 0)
                thumbnail.draw(in: CGRect(origin: .zero, size: size))
                self.lastRecordedVideoThumbnail = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
                logger.debug("Resized thumbnail to reduce memory usage")
            }
            
            // Force a GC cycle
            logger.debug("Memory cleanup after recording complete")
        }

        // Restore exposure state if it was automatically locked for recording
        if self.settingsModel.isExposureLockEnabledDuringRecording, let modeToRestore = previousExposureMode {
            logger.info("Recording stopped: Restoring previous exposure state. SP Active: \\(isShutterPriorityEnabled), Stored Mode: \\(String(describing: modeToRestore))")

            // --- Modification Start ---
            if isShutterPriorityEnabled {
                // Restore Shutter Priority auto-ISO (if it was locked for recording)
                logger.info("SP is active, unlocking SP exposure after recording.")
                exposureService.unlockShutterPriorityExposureAfterRecording() // Use new service method
            } else {
                // Restore standard lock state (SP was OFF when recording started)
                logger.info("SP is OFF, restoring standard exposure state based on stored mode: \\(String(describing: modeToRestore))")
                switch modeToRestore {
                case .continuousAutoExposure:
                    exposureService.setAutoExposureEnabled(true) // This implicitly sets mode to auto
                    self.isExposureLocked = false // Update UI state
                    logger.info("Restored to .continuousAutoExposure.")
                case .custom:
                    // If the stored mode was custom (e.g., manual ISO/Shutter before recording without SP)
                    exposureService.setAutoExposureEnabled(false) // Set to manual mode first
                    self.isExposureLocked = false // Update UI state
                    if let iso = previousISO, let duration = previousExposureDuration {
                        logger.info("Attempting to restore previous custom ISO: \\(iso) and Duration: \\(duration.seconds)s")
                        exposureService.setCustomExposure(duration: duration, iso: iso) // Reapply specific values
                    } else {
                         logger.warning("Stored mode was .custom, but ISO/Duration not available. Reverting to manual mode without specific values.")
                    }
                case .locked:
                    // If the stored mode was already locked (unlikely if lock-on-record is true, but handle anyway)
                    exposureService.setExposureLock(locked: true) // Re-apply lock
                    self.isExposureLocked = true // Update UI state
                    logger.info("Restored to .locked.")
                default:
                    // Fallback: revert to auto if modeToRestore is unexpected
                    logger.warning("Could not restore unknown previous standard exposure mode: \\(String(describing: modeToRestore)). Reverting to auto.")
                    exposureService.setAutoExposureEnabled(true)
                    self.isExposureLocked = false
                }
            }
            // --- Modification End ---

            // Clear the stored state regardless of which path was taken
            previousExposureMode = nil
            previousISO = nil
            previousExposureDuration = nil
        } else if self.settingsModel.isExposureLockEnabledDuringRecording {
             logger.warning("Lock during recording enabled, but no previous exposure mode was stored. Cannot restore.")
        }

        // Notify RotationLockedContainer about recording state change
        NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)

        // Update watch state
        sendStateToWatch()

        // Stop location updates for GPS tagging
        locationService.stopUpdating()
    }
    
    private func updateVideoConfiguration() {
        // Update recording service with new codec
        recordingService.setVideoConfiguration(
            frameRate: selectedFrameRate,
            resolution: selectedResolution,
            codec: selectedCodec
        )
        
        print("\n=== Updating Video Configuration ===")
        print("🎬 Selected Codec: \(selectedCodec.rawValue)")
        print("🎨 Apple Log Enabled: \(isAppleLogEnabled)")
        
        if selectedCodec == .proRes {
            print("✅ Configured for ProRes recording")
        } else {
            print("✅ Configured for HEVC recording")
            print("📊 Bitrate: \(selectedCodec.bitrate / 1_000_000) Mbps")
        }
        
        print("=== End Video Configuration ===\n")
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    // Track frame counts for logging
    private var videoFrameCount = 0
    private var audioFrameCount = 0
    private var successfulVideoFrames = 0
    private var failedVideoFrames = 0
    // Add flag to track if frames are being processed after resume
    private var isProcessingFramesAfterResume = false // NEW

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

    private func getVideoTransform(for orientation: UIInterfaceOrientation) -> CGAffineTransform {
        switch orientation {
        case .portrait:
            return CGAffineTransform(rotationAngle: .pi/2) // 90 degrees clockwise
        case .portraitUpsideDown:
            return CGAffineTransform(rotationAngle: -.pi/2) // 90 degrees counterclockwise
        case .landscapeLeft: // USB on right
            return CGAffineTransform(rotationAngle: .pi) // 180 degrees (was .identity)
        case .landscapeRight: // USB on left
            return .identity // No rotation (was .pi)
        default:
            return .identity
        }
    }

    // MARK: - LUT Processing

    private func applyLUT(to image: CIImage, using filter: CIFilter) -> CIImage? {
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    // MARK: - Error Handling

    // Common error handler for all delegate protocols
    // REMOVED - Moved to CameraDeviceServiceDelegate extension
    // func didEncounterError(_ error: CameraError) {
    //    DispatchQueue.main.async {
    //        self.error = error
    //    }
    // }

    // MARK: - Video Frame Processing
    
    func processVideoFrame(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        // Process the frame if needed, or handle any frame-level logic
        // For now, just returning the pixel buffer from the sample buffer
        return CMSampleBufferGetImageBuffer(sampleBuffer)
    }
    
    // MARK: - Orientation Handling (NEW)
    
    func setCamera(_ device: AVCaptureDevice?) {
        Task {
            guard self.device != nil else { return }
            // ... other logic
        }
    }

    // MARK: - Watch Connectivity

    private func setupWatchConnectivity() {
        if WCSession.isSupported() {
            wcSession = WCSession.default
            wcSession?.delegate = self
            wcSession?.activate()
            wcLogger.info("Watch Connectivity session activated.")
        } else {
            wcLogger.warning("Watch Connectivity is not supported on this device.")
        }
    }

    private func sendStateToWatch() {
        guard let session = wcSession, session.isReachable else {
            // Log differently if app isn't active vs watch not reachable
            if !(wcSession?.isReachable ?? false) {
                    wcLogger.debug("Watch not reachable, skipping state update.")
            } else {
                    wcLogger.debug("Watch reachable but session not ready or app not active, skipping context send.")
            }
            return
        }

        // Build the context dictionary
        var context: [String: Any] = [
            "isRecording": isRecording,
            "isAppActive": isAppCurrentlyActive,
            "selectedFrameRate": selectedFrameRate
        ]
        
        // Add start time only if recording
        if isRecording, let startTime = recordingStartTime {
            context["recordingStartTime"] = startTime.timeIntervalSince1970
        }
        
        do {
            try session.updateApplicationContext(context)
            wcLogger.info("Sent application context to watch: \(context)")
        } catch {
            wcLogger.error("Error sending application context to watch: \(error.localizedDescription)")
        }
    }

    // MARK: - App Lifecycle State Update

    func setAppActive(_ active: Bool) {
        guard isAppCurrentlyActive != active else { return }
        isAppCurrentlyActive = active
        wcLogger.info("iOS App Active State changed: \(active)")
        // Start or stop session based on active state
        if active {
            logger.info("App became active. Session start will be handled by AppLifecycleObserver.") // Modified log
            // startSession() // REMOVED: Let AppLifecycleObserver handle this
        } else {
            logger.info("App became inactive, requesting session stop.")
            stopSession()
        }
        // Send updated state immediately
        sendStateToWatch()
    }

    // MARK: - Camera Actions Triggered by Watch

    @MainActor
    private func handleWatchMessage(_ message: [String: Any]) {
        wcLogger.info("Received message from watch: \(message)")
        if let command = message["command"] as? String {
            switch command {
            case "startRecording":
                // Ensure app is active before starting from watch
                guard isAppCurrentlyActive else {
                    wcLogger.warning("Received startRecording command but iOS app is not active. Ignoring.")
                    return
                }
                Task {
                    await startRecording()
                }
            case "stopRecording":
                // Allow stopping even if app isn't technically active (might be in background)
                Task {
                    await stopRecording()
                }
            default:
                wcLogger.warning("Received unknown command from watch: \(command)")
            }
        }
    }

    // MARK: - Helper to send launch command

    private func sendLaunchCommandToWatch() {
        guard let session = wcSession, session.isReachable else {
            wcLogger.debug("Watch not reachable, skipping launch command send.")
            return
        }

        let message = ["command": "launchApp"]
        session.sendMessage(message, replyHandler: nil) { [weak self] error in
            self?.wcLogger.error("Error sending launch command to watch: \(error.localizedDescription)")
        }
        wcLogger.info("Sent launch command to watch: \(message)")
    }

    // MARK: - Exposure Lock

    /// Toggles the exposure lock state.
    func toggleExposureLock() {
        // Prevent manual AE lock if Shutter Priority is active
        guard !isShutterPriorityEnabled else {
             logger.info("Manual exposure lock is disabled while Shutter Priority is active.")
             return
        }
        isExposureLocked.toggle()
        logger.info("Exposure lock toggled to: \(self.isExposureLocked)")
        // The didSet on isExposureLocked calls updateExposureLock()
    }

    private func updateExposureLock() {
        // This should now only be called when the user manually toggles the lock (and SP is off)
        logger.info("Updating exposure lock state in service to: \(self.isExposureLocked)")
        exposureService?.setExposureLock(locked: self.isExposureLocked)
    }

    // MARK: - Shutter Priority Toggle
    /// Toggles 180° shutter‑priority mode on/off.
    func toggleShutterPriority() {
        // Ensure frame rate is valid
        guard selectedFrameRate > 0 else {
            logger.error("Cannot toggle Shutter Priority: Invalid frame rate (0).")
            // Optionally show an error to the user
            return
        }

        // Calculate target duration for 180 degrees
        let targetDurationSeconds = 1.0 / (selectedFrameRate * 2.0)
        let targetDuration = CMTimeMakeWithSeconds(targetDurationSeconds, preferredTimescale: 1_000_000) // High precision

        if !isShutterPriorityEnabled {
            logger.info("ViewModel: Enabling Shutter Priority with duration \\(targetDurationSeconds)s.")
            exposureService.enableShutterPriority(duration: targetDuration)
            isShutterPriorityEnabled = true // Update state AFTER calling service
            // ADDED: Ensure standard AE lock UI turns off when SP enables
            if self.isExposureLocked {
                logger.info("SP enabled, turning off manual exposure lock state.")
                self.isExposureLocked = false // This will trigger updateExposureLock, but it's okay here as SP isn't active *yet* in ExposureService
            }
        } else {
            logger.info("ViewModel: Disabling Shutter Priority.")
            exposureService.disableShutterPriority()
            isShutterPriorityEnabled = false // Update state AFTER calling service
            // No need to change isExposureLocked state here - leave it as it was before SP was disabled
        }
        // Remove the old logic that directly manipulated isAutoExposureEnabled and updateShutterAngle
    }

    private func handleSessionRunningStateChange(_ isRunning: Bool) {
        if isRunning {
            startPollingWhiteBalance()
        } else {
            stopPollingWhiteBalance()
        }
    }

    private func startPollingWhiteBalance() {
        logger.info("Starting WB polling timer.")
        // Invalidate existing timer just in case
        stopPollingWhiteBalance()
        
        wbPollingTimerCancellable = Timer.publish(every: wbPollingInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pollCurrentWhiteBalance()
            }
    }

    private func stopPollingWhiteBalance() {
        logger.info("Stopping WB polling timer.")
        wbPollingTimerCancellable?.cancel()
        wbPollingTimerCancellable = nil
    }

    private func pollCurrentWhiteBalance() {
        guard self.isWhiteBalanceAuto else {
            // If not in auto WB mode, don't let polling override manual settings.
            // logger.trace("WB Poll: Manual WB mode active, skipping poll update.") // Optional: for debugging
            return
        }

        guard let currentTemperature = exposureService.getCurrentWhiteBalanceTemperature() else {
            // logger.trace("WB Poll: Exposure service returned nil, skipping update.")
            return
        }
        
        // Only update if the value actually changed significantly to avoid needless UI churn
        // Using a threshold of 1 Kelvin change
        if abs(self.whiteBalance - currentTemperature) >= 1.0 {
            // logger.debug("WB Poll: Updating white balance from \(self.whiteBalance) to \(currentTemperature)")
            self.whiteBalance = currentTemperature
        } else {
             // logger.trace("WB Poll: Temperature \(currentTemperature) hasn't changed significantly from \(self.whiteBalance). Skipping update.")
        }
    }

    // Setup additional notification observers for new settings
    private func setupSettingObservers() {
        // Resolution changes
        NotificationCenter.default.addObserver(
            forName: .selectedResolutionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let resolution = Resolution(rawValue: self.settingsModel.selectedResolutionRaw),
               resolution != self.selectedResolution {
                self.selectedResolution = resolution
            }
        }
        
        // Codec changes
        NotificationCenter.default.addObserver(
            forName: .selectedCodecChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let codec = VideoCodec(rawValue: self.settingsModel.selectedCodecRaw),
               codec != self.selectedCodec {
                self.selectedCodec = codec
            }
        }
        
        // Frame rate changes
        NotificationCenter.default.addObserver(
            forName: .selectedFrameRateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.selectedFrameRate != self.settingsModel.selectedFrameRate {
                self.selectedFrameRate = self.settingsModel.selectedFrameRate
                self.updateFrameRate(self.selectedFrameRate)
            }
        }
        
        // Apple Log changes
        NotificationCenter.default.addObserver(
            forName: .appleLogSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.isAppleLogEnabled != self.settingsModel.isAppleLogEnabled {
                self.isAppleLogEnabled = self.settingsModel.isAppleLogEnabled
            }
        }
    }
    
    // Wrapper methods to update settings
    func updateResolution(_ resolution: Resolution) {
        selectedResolution = resolution
    }
    
    func updateCodec(_ codec: VideoCodec) {
        selectedCodec = codec
    }
    
    func updateColorSpace(isAppleLogEnabled: Bool) {
        self.isAppleLogEnabled = isAppleLogEnabled
    }

    // MARK: - Session Control
    /// Start the AVCaptureSession on the dedicated queue and update state
    func startSession() {
        // Check the @Published var first.
        if isSessionRunning {
            logger.info("[SessionControl] Start session requested (isSessionRunning is true). Verifying actual session state.")
            sessionQueue.async { [weak self] in // Verify actual state on session queue
                guard let self = self else { return }
                if self.session.isRunning {
                    self.logger.info("[SessionControl] Session is indeed physically running. No need to restart. Assuming configuration is correct. Stabilization updates should be event-driven from settings changes.")
                    // Ensure @Published var is in sync if it wasn't
                    DispatchQueue.main.async {
                        if !self.isSessionRunning { self.isSessionRunning = true }
                    }
                } else {
                    // isSessionRunning was true, but session.isRunning is false. This is an inconsistent state.
                    self.logger.warning("[SessionControl] Inconsistent state: isSessionRunning true, but session.isRunning false. Proceeding to start.")
                    DispatchQueue.main.async { self.isSessionRunning = false } // Correct the @Published var
                    self.performSessionStartSequence() // Call the actual start logic
                }
            }
            return // Return from the main function body of startSession
        }

        // Check if device is nil, which would indicate session wasn't properly set up
        if self.device == nil {
            logger.warning("[SessionControl] Start session requested but camera device is nil. Attempting to set up session first.")
            
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                do {
                    // First try to set up the session
                    try self.cameraSetupService.setupSession()
                    self.logger.info("[SessionControl] Camera session setup completed successfully, now starting session")
                    
                    // Only attempt to start session if setup was successful
                    self.performSessionStartSequence()
                } catch {
                    self.logger.error("[SessionControl] Failed to setup camera session: \(error)")
                    DispatchQueue.main.async {
                        self.error = error as? CameraError ?? .setupFailed
                        self.status = .failed
                    }
                }
            }
            return
        }

        // If isSessionRunning is false and device is not nil, proceed to start it.
        logger.info("[SessionControl] Start session requested (isSessionRunning is false).")
        
        // Prepare Metal preview for new session (e.g., flush texture cache)
        // This is called from startSession, which is invoked on the main thread by AppLifecycleObserver via ScenePhase.
        logger.info("[SessionControl] Calling metalPreviewDelegate.prepareForNewSession() synchronously on main thread.")
        metalPreviewDelegate?.prepareForNewSession()

        performSessionStartSequence()
    }

    private func performSessionStartSequence() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // This guard protects against race conditions if performSessionStartSequence is called multiple times quickly.
            guard !self.session.isRunning else {
                self.logger.info("[SessionControl] Session started running between initial check and performSessionStartSequence execution.")
                DispatchQueue.main.async {
                    if !self.isSessionRunning { self.isSessionRunning = true }
                }
                return
            }

            self.logger.info("[SessionControl] Attempting to start session via performSessionStartSequence...")
            // Remove video output delegate before starting
            self.unifiedVideoOutput?.setSampleBufferDelegate(nil, queue: nil)
            // Reapply video stabilization setting before starting session
            // This is the correct place to set it up for a new session start.
            self.setupUnifiedVideoOutput(enableStabilization: self.settingsModel.isVideoStabilizationEnabled)
            self.session.startRunning()
            DispatchQueue.main.async {
                let sessionSuccessfullyStarted = self.session.isRunning
                self.isSessionRunning = sessionSuccessfullyStarted
                self.status = sessionSuccessfullyStarted ? .running : .failed
                
                if sessionSuccessfullyStarted {
                    self.logger.info("[SessionControl] Session started successfully: \\(self.isSessionRunning)")
                    self.error = nil
                    // Re-attach KVO observers AFTER session is confirmed running
                    if let currentDevice = self.device {
                        self.logger.info("[SessionControl] Re-attaching ExposureService observers for device: \\(currentDevice.localizedName)")
                        self.exposureService.setDevice(currentDevice)
                        // --- Ensure Apple Log (or selected color space) is re-applied after session start ---
                        if self.isAppleLogEnabled && self.isAppleLogSupported {
                            self.logger.info("[SessionControl] Re-applying Apple Log color space after session start...")
                            Task {
                                do {
                                    try await self.videoFormatService.configureAppleLog()
                                    try await self.cameraDeviceService.reconfigureSessionForCurrentDevice()
                                    self.logger.info("✅ [SessionControl] Successfully re-applied Apple Log color space after session start.")
                                    // Reapply video stabilization setting after AppleLog reconfiguration - ensure this doesn't cause another full output rebuild if not needed
                                    self.updateVideoStabilizationMode(enabled: self.settingsModel.isVideoStabilizationEnabled, forceReconfigure: false)
                                } catch {
                                    self.logger.error("❌ [SessionControl] Failed to re-apply Apple Log color space after session start: \\(error)")
                                }
                            }
                        } else if !self.isAppleLogEnabled {
                            self.logger.info("[SessionControl] Re-applying Rec. 709 / P3 color space after session start...")
                            Task {
                                do {
                                    try await self.videoFormatService.resetAppleLog()
                                    try await self.cameraDeviceService.reconfigureSessionForCurrentDevice()
                                    self.logger.info("✅ [SessionControl] Successfully re-applied Rec. 709 / P3 color space after session start.")
                                    self.updateVideoStabilizationMode(enabled: self.settingsModel.isVideoStabilizationEnabled, forceReconfigure: false)
                                } catch {
                                    self.logger.error("❌ [SessionControl] Failed to re-apply Rec. 709 / P3 color space after session start: \\(error)")
                                }
                            }
                        }
                        // --- END color space re-application ---
                    } else {
                        self.logger.warning("[SessionControl] Session started but device is nil. Cannot re-attach ExposureService observers.")
                    }
                    // Reapply video stabilization setting after session start
                    // Make this call conditional or ensure updateVideoStabilizationMode is smart
                    self.updateVideoStabilizationMode(enabled: self.settingsModel.isVideoStabilizationEnabled, forceReconfigure: true) // Force reconfigure on new session
                } else {
                    self.error = CameraError.sessionFailedToStart
                    self.logger.error("[SessionControl] Session failed to start (isSessionRunning is false after startRunning call). Setting status to failed.")
                }
            }
        }
    }

    /// Stop the AVCaptureSession on the dedicated queue
    func stopSession() {
        // ADD GUARD: Check if session is already stopped (using the published property)
        guard isSessionRunning else {
            logger.info("[SessionControl] Stop session requested, but session is not running (isSessionRunning=false).")
            return
        }
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // Check the actual session state inside the queue
            guard self.session.isRunning else {
                self.logger.info("[SessionControl] Stop session requested, but session was already stopped before async block executed.")
                // Ensure main thread state matches
                DispatchQueue.main.async {
                    if self.isSessionRunning { self.isSessionRunning = false }
                }
                return
            }
            
            self.logger.info("[SessionControl] Attempting to stop session...")
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = false
                self.logger.info("[SessionControl] Session stopped.")
            }
        }
    }

    // MARK: - Interruption Handlers
    @objc private func sessionInterrupted(_ notification: Notification) {
        // Remove observers IMMEDIATELY upon interruption notification
        exposureService.removeDeviceObservers()
        logger.warning("[SessionControl] ExposureService observers removed due to session interruption.")

        logger.warning("[SessionControl] Session interrupted: \(notification.userInfo ?? [:])")
        // Check the reason for interruption
        if let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
           let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) {
            logger.warning("[SessionControl] Interruption Reason: \(String(describing: reason))")
            
            // Only show error for non-background interruptions
            if reason != .videoDeviceNotAvailableInBackground {
                DispatchQueue.main.async {
                    self.error = .sessionInterrupted
                }
            }
        }
        
        // Update session state immediately
        DispatchQueue.main.async {
            self.isSessionRunning = false
        }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        logger.info("[SessionControl] Session interruption ended. Checking app state...")
        
        // Clear any existing session interruption error
        DispatchQueue.main.async {
            if case .sessionInterrupted = self.error {
                self.error = nil
            }
        }
        
        // Only attempt restart if the app is currently active
        if isAppCurrentlyActive {
            logger.info("[SessionControl] App is active. Requesting session restart.")
            startSession() // Attempt restart
            
            // Re-apply shutter priority if needed
            if isShutterPriorityEnabled {
                logger.info("[SessionControl] Ensuring shutter priority is reapplied after interruption")
                // Using longer delay to ensure the session is fully running
                reapplyShutterPriority(after: 0.5, lockIfRecording: isRecording) 
            }
        } else {
            logger.info("[SessionControl] App is not active. Deferring session restart to AppLifecycleObserver.")
            // Do nothing, let AppLifecycleObserver handle it when app becomes active
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        // Log the specific AVError code if available
        var specificErrorCode: AVError.Code? = nil
        if let avError = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError {
            specificErrorCode = avError.code
            logger.error("[SessionControl] Runtime Error is AVError. Code: \(specificErrorCode!.rawValue) - \(avError.localizedDescription)")
        } else if let nsError = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError {
             logger.error("[SessionControl] Runtime Error is NSError. Code: \(nsError.code) - Domain: \(nsError.domain) - \(nsError.localizedDescription)")
        } else {
             logger.error("[SessionControl] Runtime Error received, but couldn't extract specific error object. UserInfo: \(notification.userInfo ?? [:])")
        }

        // !!! CRITICAL: Remove observers immediately BEFORE updating state for any runtime error
        logger.warning("[SessionControl] Runtime Error detected. Removing ExposureService observers immediately.")
        exposureService.removeDeviceObservers()

        // --- Handle 'Cannot Record' error by reconfiguring session ---
        if specificErrorCode == .mediaServicesWereReset || specificErrorCode == .sessionWasInterrupted {
            logger.error("[SessionControl] Recording/Session error detected. Reconfiguring session...")
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                do {
                    try self.cameraSetupService.setupSession()
                    DispatchQueue.main.async {
                        self.startSession()
                    }
                } catch {
                    self.logger.error("[SessionControl] Failed to reconfigure session after CannotRecord: \(error)")
                }
            }
            return
        }

        // Check if it's media services reset
        if specificErrorCode == .mediaServicesWereReset {
             logger.error("[SessionControl] Media services were reset. Avoiding immediate restart. Reconfiguration or app lifecycle should handle restart.")
             DispatchQueue.main.async {
                 self.isSessionRunning = false // Explicitly set running to false
                 self.status = .failed
                 self.error = .mediaServicesWereReset // Use specific error
             }
             return // Exit early for media services reset
        }

        // For OTHER runtime errors (AVError or NSError):
        logger.error("[SessionControl] Generic runtime error occurred (Code: \(specificErrorCode?.rawValue ?? -1)). Session stopping. Recovery will be attempted by lifecycle events.")
        DispatchQueue.main.async {
            self.isSessionRunning = false // Ensure session state is false
            self.status = .failed // Indicate failure
            self.error = .sessionRuntimeError(code: specificErrorCode?.rawValue ?? -1)
        }
        // DO NOT restart session here for generic errors
    }

    func updateVideoStabilizationMode(enabled: Bool, forceReconfigure: Bool = true) {
        logger.info("Updating video stabilization mode setting to: \\(enabled). Force reconfigure: \\(forceReconfigure)")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            if !forceReconfigure {
                // If not forcing reconfigure, just try to update the preferred mode on existing connection
                if let connection = self.unifiedVideoOutput?.connection(with: .video), connection.isVideoStabilizationSupported {
                    let newMode: AVCaptureVideoStabilizationMode
                    if enabled {
                        if let currentDevice = self.device {
                            if currentDevice.activeFormat.isVideoStabilizationModeSupported(.standard) {
                                newMode = .standard
                            } else if currentDevice.activeFormat.isVideoStabilizationModeSupported(.auto) {
                                newMode = .auto
                            } else {
                                newMode = .off
                            }
                        } else {
                            newMode = .off // Fallback
                        }
                    } else {
                        newMode = .off
                    }

                    if connection.preferredVideoStabilizationMode != newMode {
                        connection.preferredVideoStabilizationMode = newMode
                        self.logger.info("UNIFIED_VIDEO: Stabilization mode updated on existing connection to \\(newMode.rawValue) without full output reconfiguration.")
                    } else {
                         self.logger.info("UNIFIED_VIDEO: Stabilization mode already \\(newMode.rawValue). No change made to existing connection.")
                    }
                    return // Avoid full reconfiguration
                }
            }
            
            // Fallback to full reconfiguration if forced, or if connection update isn't possible/sufficient
            self.logger.info("Proceeding with full video output reconfiguration for stabilization change.")
            self.setupUnifiedVideoOutput(enableStabilization: enabled)
        }
    }
    
    // Modified to accept optional state parameter
    func setupUnifiedVideoOutput(enableStabilization: Bool? = nil) {
        logger.info("Setting up unified video output... Stabilization state passed: \(String(describing: enableStabilization))")
        session.beginConfiguration()
        
        // Remove any existing video outputs
        session.outputs.forEach { output in
            if output is AVCaptureVideoDataOutput {
                session.removeOutput(output)
            }
        }
        
        // Create and configure the unified video output
        let videoOutput = AVCaptureVideoDataOutput()
        
        // Use high priority queue for preview frames
        let highPriorityQueue = DispatchQueue(label: "com.camera.preview", qos: .userInteractive, attributes: .concurrent)
        videoOutput.setSampleBufferDelegate(self, queue: highPriorityQueue)
        
        // Get available pixel formats
        let availableFormats = videoOutput.availableVideoPixelFormatTypes
        
        // Define our preferred formats
        let appleLogPixelFormat: OSType = 2016686642 // 'x422' 10-bit 4:2:2 Bi-Planar
        let standardPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let fallbackPixelFormat: OSType = kCVPixelFormatType_32BGRA
        
        // Log available formats for debugging
        logger.debug("Available pixel formats: \(availableFormats.map { String(format: "%08x", $0) })")
        
        // Choose pixel format based on availability and Apple Log setting
        var selectedFormat: OSType
        
        if self.isAppleLogEnabled && availableFormats.contains(appleLogPixelFormat) {
            selectedFormat = appleLogPixelFormat
            logger.info("Using Apple Log pixel format (x422)")
        } else if availableFormats.contains(standardPixelFormat) {
            selectedFormat = standardPixelFormat
            logger.info("Using standard YUV pixel format (420v)")
        } else if availableFormats.contains(fallbackPixelFormat) {
            selectedFormat = fallbackPixelFormat
            logger.info("Using fallback BGRA pixel format")
        } else {
            logger.error("No supported pixel formats available")
            session.commitConfiguration()
            return
        }
        
        // Configure video settings
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: selectedFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        // Ensure we drop frames to maintain real-time preview
        videoOutput.alwaysDiscardsLateVideoFrames = true
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            unifiedVideoOutput = videoOutput
            
            // Configure video connection for minimal latency
            if let connection = videoOutput.connection(with: .video) {
                // Enable video stabilization if available
                if connection.isVideoStabilizationSupported {
                    // Determine desired state: use passed value if available, else read from model
                    let shouldEnableStabilization = enableStabilization ?? settingsModel.isVideoStabilizationEnabled
                    logger.info("UNIFIED_VIDEO: Determined stabilization state: \(shouldEnableStabilization) (Passed: \(String(describing: enableStabilization)), Model: \(self.settingsModel.isVideoStabilizationEnabled))")

                    // Check the setting
                    if shouldEnableStabilization {
                        // Check format support for specific modes (requires device access)
                        if let currentDevice = self.device {
                            // Prioritize .standard for lower latency
                            if currentDevice.activeFormat.isVideoStabilizationModeSupported(.standard) {
                                connection.preferredVideoStabilizationMode = .standard
                                logger.info("UNIFIED_VIDEO: Stabilization set to STANDARD (Format supports)")
                            } else if currentDevice.activeFormat.isVideoStabilizationModeSupported(.auto) { // Fallback to .auto
                                connection.preferredVideoStabilizationMode = .auto
                                logger.info("UNIFIED_VIDEO: Stabilization set to AUTO (Format supports, Standard unavailable)")
                            } else {
                                connection.preferredVideoStabilizationMode = .off
                                logger.warning("UNIFIED_VIDEO: Stabilization requested but format supports neither Standard nor Auto. Setting to OFF.")
                            }
                        } else {
                            // Fallback if device is nil (shouldn't happen here but good practice)
                            connection.preferredVideoStabilizationMode = .off
                            logger.warning("UNIFIED_VIDEO: Cannot check format support (device nil). Stabilization set to OFF.")
                        }
                    } else {
                        connection.preferredVideoStabilizationMode = .off
                        logger.info("UNIFIED_VIDEO: Stabilization set to OFF (User setting)")
                    }
                } else {
                    logger.warning("UNIFIED_VIDEO: Stabilization not supported on this connection.")
                }
                
                // Set video orientation
                connection.videoRotationAngle = 0  // 0 degrees for portrait
                
                // Minimize latency
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
                
                logger.info("UNIFIED_VIDEO: Connection configured - rotation: \(connection.videoRotationAngle)°")
            }
            
            logger.info("Successfully added video output to session")
        } else {
            logger.error("Failed to add unified video output to session")
        }
        
        session.commitConfiguration()
    }

    // Update the AVCaptureVideoDataOutputSampleBufferDelegate method
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == self.unifiedVideoOutput {
            self.videoFrameCount += 1

            guard CMSampleBufferIsValid(sampleBuffer) else {
                logger.error("[VideoCapture] Invalid sample buffer received")
                return
            }
            
            // Skip buffer copying for preview frames to reduce latency
            self.metalPreviewDelegate?.updateTexture(with: sampleBuffer)
            
            // Only copy buffer if we're recording
            if self.isRecording {
                var copiedBuffer: CMSampleBuffer?
                let copyStatus = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleBufferOut: &copiedBuffer)
                
                if copyStatus == noErr, let copiedBuffer = copiedBuffer {
                    self.recordingService?.process(sampleBuffer: copiedBuffer)
                }
            }
            
            // Update frame count silently
            self.videoFrameCount += 1
        } else {
            // Audio Frame Processing
            self.audioFrameCount += 1
        }
    }

    // Add method to set recording service
    func setRecordingService(_ service: RecordingService) {
        self.recordingService = service
    }

    func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            
            // Configure inputs
            self.configureVideoInput()
            self.configureAudioInput()
            
            // Configure unified video output
            self.setupUnifiedVideoOutput()
            
            self.session.commitConfiguration()
            
            // Start running the session
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
        }
    }

    private func configureVideoInput() {
        logger.info("Configuring video input")
        
        // Remove any existing video inputs
        session.inputs.forEach { input in
            if input.ports.contains(where: { $0.mediaType == .video }) {
                session.removeInput(input)
            }
        }
        
        // Get the default video device
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            logger.error("Failed to get default video device")
            return
        }
        
        do {
            // Create and add video device input
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
                self.videoDeviceInput = videoInput
                self.device = videoDevice
                logger.info("Successfully added video input to session")
            } else {
                logger.error("Could not add video device input to session")
            }
        } catch {
            logger.error("Error creating video device input: \(error.localizedDescription)")
        }
    }

    private func configureAudioInput() {
        logger.info("Configuring audio input (MIC DISABLED FOR HAPTIC TEST)")
        
        // Remove any existing audio inputs
        session.inputs.forEach { input in
            if input.ports.contains(where: { $0.mediaType == .audio }) {
                session.removeInput(input)
            }
        }
        
        // --- TEMPORARILY DISABLED: Do not add audio input for haptic feedback testing ---
        /*
        // Get the default audio device
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            logger.error("Failed to get default audio device")
            return
        }
        
        do {
            // Create and add audio device input
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
                logger.info("Successfully added audio input to session")
            } else {
                logger.error("Could not add audio device input to session")
            }
        } catch {
            logger.error("Error creating audio device input: \(error.localizedDescription)")
        }
        */
    }

    // MARK: - Focus & Exposure Controls
    /// Sets focus & exposure to a point (normalized) and optionally locks after.
    @MainActor
    func focus(at point: CGPoint, lockAfter: Bool) {
        print("📍 [CameraViewModel.focus] Called with point: \(point), lockAfter: \(lockAfter)")
        cameraDeviceService.setFocusAndExposure(at: point, lock: lockAfter)
    }

    /// Updates exposure compensation by adding delta to current value.
    @MainActor
    func adjustExposureBias(by delta: Float) {
        let newBias = exposureBias + delta
        exposureService.updateExposureTargetBias(newBias)
    }

    // MARK: - Shutter Priority Re-application (NEW)
    /// Re-applies Shutter Priority using the *current* device frame-rate.
    /// - Parameters:
    ///   - delay: Optional delay before applying, useful if the device needs a brief moment after re-configuration.
    ///   - lockIfRecording: If `true` and the app is currently recording *and* the "Lock Exposure During Recording" setting is enabled, the exposure will be locked after SP is re-enabled.
    private func reapplyShutterPriority(after delay: TimeInterval = 0.0,
                                        lockIfRecording: Bool = true) {
        guard isShutterPriorityEnabled else { return }
        guard self.device != nil else {
            logger.error("[SP-Reapply] No active device – cannot re-apply Shutter Priority.")
            return
        }

        let applyBlock = { [weak self] in
            guard let self = self else { return }
            // Use our new method for consistency
            self.ensureShutterPriorityConsistency()
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: applyBlock)
        } else {
            DispatchQueue.main.async(execute: applyBlock)
        }
    }

    // MARK: - Shutter Priority Consistency
    /// Ensures shutter priority is correctly applied with 180° shutter angle.
    /// This method is called after lens switches, background returns, and other events
    /// where shutter priority settings might need to be re-applied.
    func ensureShutterPriorityConsistency() {
        guard isShutterPriorityEnabled, let device = self.device else {
            logger.debug("[ensureShutterPriorityConsistency] Shutter priority not enabled or no device available")
            return
        }
        // Device readiness check
        guard session.isRunning else {
            logger.warning("[ensureShutterPriorityConsistency] Session not running, skipping SP re-apply.")
            return
        }
        logger.info("[ensureShutterPriorityConsistency] Ensuring 180° shutter is correctly applied")
        // Get the actual frame rate from the device if possible, otherwise use selected value
        let actualFrameRate: Double
        if device.activeVideoMaxFrameDuration.isValid,
           device.activeVideoMaxFrameDuration.timescale != 0 {
            actualFrameRate = 1.0 / device.activeVideoMaxFrameDuration.seconds
            logger.info("[ensureShutterPriorityConsistency] Using device frame rate: \(String(format: "%.2f", actualFrameRate)) fps")
        } else {
            actualFrameRate = self.selectedFrameRate > 0 ? self.selectedFrameRate : 24.0
            logger.info("[ensureShutterPriorityConsistency] Using selected frame rate: \(String(format: "%.2f", actualFrameRate)) fps")
        }
        // Cache last ISO before re-applying SP
        if let iso = self.iso as Float? { self.lastSPISO = iso }
        // Calculate 180° shutter duration
        let targetDurationSeconds = 1.0 / (actualFrameRate * 2.0)
        let targetDuration = CMTimeMakeWithSeconds(targetDurationSeconds, preferredTimescale: 1_000_000)
        logger.info("[ensureShutterPriorityConsistency] Applying 180° shutter duration: \(String(format: "%.5f", targetDurationSeconds))s")
        // Apply shutter priority with the calculated duration and cached ISO if available
        if let lastISO = lastSPISO {
            exposureService.enableShutterPriority(duration: targetDuration, initialISO: lastISO)
        } else {
            exposureService.enableShutterPriority(duration: targetDuration)
        }
        // If currently recording and exposure lock is enabled during recording, re-lock
        if isRecording && settingsModel.isExposureLockEnabledDuringRecording {
            logger.info("[ensureShutterPriorityConsistency] Re-locking exposure for ongoing recording")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.exposureService.lockShutterPriorityExposureForRecording()
            }
        }
    }

    private func cancelPendingShutterPriorityReapply() {
        shutterPriorityReapplyTask?.cancel()
        shutterPriorityReapplyTask = nil
    }

    @MainActor
    func setPreviewView(_ view: UIView) {
        owningView = view
        if #available(iOS 17.2, *) {
            // Create and attach volume button handler
            Task { @MainActor in
                volumeButtonHandler = VolumeButtonHandler(viewModel: self)
                volumeButtonHandler?.attachToView(view)
            }
        }
    }
    
    @MainActor
    func removePreviewView() {
        if #available(iOS 17.2, *) {
            // Detach volume button handler
            if let view = owningView {
                Task { @MainActor in
                    volumeButtonHandler?.detachFromView(view)
                    volumeButtonHandler = nil
                }
            }
        }
        owningView = nil
    }

    func setAutoExposureEnabled(_ enabled: Bool) {
        // Only update if the state actually changes
        guard isAutoExposureEnabled != enabled else { return }
        isAutoExposureEnabled = enabled
        currentExposureMode = enabled ? .auto : .manual
        exposureService.setAutoExposureEnabled(enabled)
    }

    func enableShutterPriority(duration: CMTime, initialISO: Float? = nil) {
        exposureService.enableShutterPriority(duration: duration, initialISO: initialISO)
        currentExposureMode = .shutterPriority
    }

    func disableShutterPriority() {
        exposureService.disableShutterPriority()
        currentExposureMode = .auto
    }

    func setExposureLock(locked: Bool) {
        exposureService.setExposureLock(locked: locked)
        currentExposureMode = locked ? .locked : (isAutoExposureEnabled ? .auto : .manual)
    }

    private struct ExposureState {
        let iso: Float
        let duration: CMTime
        let mode: ExposureMode
        static func capture(from device: AVCaptureDevice, mode: ExposureMode) -> ExposureState {
            return ExposureState(
                iso: device.iso,
                duration: device.exposureDuration,
                mode: mode
            )
        }
    }

    func prepareForLensSwitch() {
        guard let device = device else { return }
        lastKnownGoodState = ExposureState.capture(from: device, mode: currentExposureMode)
    }

    func restoreAfterLensSwitch() {
        guard let state = lastKnownGoodState,
              let device = device else { return }
        switch state.mode {
        case .shutterPriority:
            enableShutterPriority(duration: state.duration, initialISO: state.iso)
        case .locked:
            exposureService.setExposureLock(locked: true)
        case .manual:
            exposureService.setAutoExposureEnabled(false)
            exposureService.setCustomExposure(duration: state.duration, iso: state.iso)
        case .auto:
            exposureService.setAutoExposureEnabled(true)
        }
        currentExposureMode = state.mode
    }
}

// MARK: - VideoFormatServiceDelegate

extension CameraViewModel: VideoFormatServiceDelegate {
    func getCurrentFrameRate() -> Double? {
        return selectedFrameRate
    }
    
    func getCurrentResolution() -> CameraViewModel.Resolution? {
        return selectedResolution
    }
    
    func didUpdateFrameRate(_ frameRate: Double) {
        // Optionally update UI or state if needed when frame rate changes
        logger.info("Delegate notified: Frame rate updated to \(frameRate) fps")
    }
}

extension CameraError {
    static func configurationFailed(message: String = "Camera configuration failed") -> CameraError {
        return .custom(message: message)
    }
}

// MARK: - CameraSetupServiceDelegate

extension CameraViewModel: CameraSetupServiceDelegate {
    func didUpdateSessionStatus(_ status: Status) {
        DispatchQueue.main.async {
            self.status = status
        }
    }
    
    func didInitializeCamera(device: AVCaptureDevice) {
        self.device = device
        logger.info("[CameraViewModel] Camera initialized with device: \(device.localizedName)")
        
        // Set Apple Log support flag based on device capabilities
        self.isAppleLogSupported = device.formats.contains { format in
            format.supportedColorSpaces.contains(.appleLog)
        }
        
        // Set the device on all services that need it
        exposureService.setDevice(device)
        recordingService.setDevice(device)
        cameraDeviceService.setDevice(device)
        videoFormatService.setDevice(device)
        
        // Initialize available lenses - move to main thread
        DispatchQueue.main.async {
            self.availableLenses = CameraLens.availableLenses()
        }
        
        // Ensure auto exposure is set on initialization
        do {
            try device.lockForConfiguration()
            if device.exposureMode != .continuousAutoExposure {
                device.exposureMode = .continuousAutoExposure
                logger.info("Initial exposure mode set to continuousAutoExposure")
            }
            device.unlockForConfiguration()
            // Update view model state to match - move to main thread
            DispatchQueue.main.async {
                self.isAutoExposureEnabled = true
                self.isExposureLocked = false
            }
        } catch {
            logger.error("Failed to set initial exposure mode: \(error.localizedDescription)")
        }

        // Re-apply Shutter Priority if it was enabled before (e.g., after app relaunch / background)
        reapplyShutterPriority(after: 0.1, lockIfRecording: false)
        
        // Update UI on main thread
        DispatchQueue.main.async {
            self.status = .running
            // Notify all observers that a valid device is now available
            NotificationCenter.default.post(name: NSNotification.Name("CameraDeviceAvailable"), object: nil)
        }
    }
    
    func didStartRunning(_ isRunning: Bool) {
        DispatchQueue.main.async {
            self.isSessionRunning = isRunning

            if isRunning {
                // Ensure SP is re-applied when session restarts (e.g., coming back from background)
                self.reapplyShutterPriority(after: 0.1, lockIfRecording: true)
            }
        }
    }
}

// MARK: - ExposureServiceDelegate

extension CameraViewModel: ExposureServiceDelegate {
    func didUpdateWhiteBalance(_ temperatureFromDevice: Float, tint: Float) {
        DispatchQueue.main.async {
            self.logger.debug("didUpdateWhiteBalance: Device Temp=\(temperatureFromDevice), Tint=\(tint). AutoWB=\(self.isWhiteBalanceAuto)")

            // Always update tint as it's coupled and not directly set by a separate picker here
            if abs(self.currentTint - tint) > 0.01 { // Only update if meaningfully different
                 self.currentTint = tint
            }

            if self.isWhiteBalanceAuto {
                // Auto WB mode: Device is authoritative.
                let tolerance: Float = 1.0 // Kelvin
                if abs(self.whiteBalance - temperatureFromDevice) > tolerance {
                    self.whiteBalance = temperatureFromDevice
                    self.logger.debug("didUpdateWhiteBalance (Auto Mode): Updated self.whiteBalance to \(temperatureFromDevice)")
                }
            } else {
                // Manual WB mode: Picker is trying to set the value.
                // Avoid fighting the picker over minor discrepancies from KVO.
                let tolerance: Float = 10.0 // Kelvin - allow larger tolerance for manual mode feedback
                if abs(self.whiteBalance - temperatureFromDevice) > tolerance {
                    // If device value is significantly different, update UI to reflect reality.
                    self.whiteBalance = temperatureFromDevice
                    self.logger.debug("didUpdateWhiteBalance (Manual Mode): Device temp \(temperatureFromDevice) significantly different from target \(self.whiteBalance). Updated self.whiteBalance.")
                }
            }
        }
    }
    
    func didUpdateISO(_ isoFromDevice: Float) {
        DispatchQueue.main.async {
            if self.isAutoExposureEnabled {
                // If auto exposure is enabled, the device is driving the ISO, so update our state.
                if abs(self.iso - isoFromDevice) > 0.01 { // Update only if meaningfully different
                    self.iso = isoFromDevice
                    // Removed excessive log
                }
            } else {
                // Manual ISO mode (isAutoExposureEnabled is false)
                // This means the user is controlling ISO, likely via SimpleWheelPicker.
                // We should be careful not to fight with the picker.
                let tolerance: Float = 0.5 // Tolerance for ISO comparison

                if abs(self.iso - isoFromDevice) > tolerance {
                    // The device ISO is significantly different from our target manual ISO.
                    // This could happen if the device couldn't achieve the target.
                    // Update self.iso to reflect reality; this might make the picker adjust.
                    // Removed excessive log
                    self.iso = isoFromDevice
                } else {
                    // Device ISO is close enough to our target. Don't update self.iso.
                    // This prevents self.iso from being jittery due to minor KVO fluctuations
                    // if self.iso was recently set by the picker.
                    // Removed excessive log
                }
            }
        }
    }
    
    func didUpdateShutterSpeed(_ speed: CMTime) {
        DispatchQueue.main.async {
            self.shutterSpeed = speed
        }
    }
    
    func didUpdateExposureTargetBias(_ bias: Float) {
        DispatchQueue.main.async {
            self.exposureBias = bias
        }
    }
}

// MARK: - RecordingServiceDelegate

extension CameraViewModel: RecordingServiceDelegate {
    func didStartRecording() {
        // Handled by the isRecording property
    }
    
    func didStopRecording() {
        // Handled by the isRecording property
    }
    
    func didFinishSavingVideo(thumbnail: UIImage?) {
        DispatchQueue.main.async {
            self.recordingFinished = true
            self.lastRecordedVideoThumbnail = thumbnail
        }
    }
    
    func didUpdateProcessingState(_ isProcessing: Bool) {
        DispatchQueue.main.async {
            self.isProcessingRecording = isProcessing
        }
    }
}

// MARK: - CameraDeviceServiceDelegate

extension CameraViewModel: CameraDeviceServiceDelegate {
    var isExposureCurrentlyLocked: Bool {
        return self.isExposureLocked
    }
    
    var isVideoStabilizationCurrentlyEnabled: Bool {
        return settingsModel.isVideoStabilizationEnabled
    }
    
    func didUpdateCurrentLens(_ lens: CameraLens) {
        logger.debug("🔄 Delegate: didUpdateCurrentLens called with \(lens.rawValue)x")
        DispatchQueue.main.async {
            self.currentLens = lens
            self.lastLensSwitchTimestamp = Date()
            self.logger.debug("🔄 Delegate: Updated currentLens to \(lens.rawValue)x and lastLensSwitchTimestamp.")
            self.cancelPendingShutterPriorityReapply()
            if self.isShutterPriorityEnabled {
                // --- Freeze UI ---
                self.isExposureUIFrozen = true
                // --- Pre-calculate ISO/duration for new lens ---
                if let device = self.device, let supportedRange = device.activeFormat.videoSupportedFrameRateRanges.first {
                    let frameRate = supportedRange.maxFrameRate
                    let targetDurationSeconds = 1.0 / (frameRate * 2.0)
                    let targetDuration = CMTimeMakeWithSeconds(targetDurationSeconds, preferredTimescale: 1_000_000)
                    let lastISO = device.iso
                    self.logger.info("[didUpdateCurrentLens] Pre-calc for SP: frameRate=\(frameRate), duration=\(targetDurationSeconds)s, ISO=\(lastISO)")
                    self.exposureService.enableShutterPriority(duration: targetDuration, initialISO: lastISO)
                }
                // --- Apply SP ASAP (no debounce, call synchronously) ---
                self.ensureShutterPriorityConsistency()
                // --- Unfreeze UI after short delay to allow SP to settle ---
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.isExposureUIFrozen = false
                }
            } else if self.isExposureLocked {
                self.logger.info("🔄 [didUpdateCurrentLens] Re-applying standard AE exposure lock after lens switch.")
                self.exposureService?.setExposureLock(locked: true)
            }
        }
    }
    
    func didUpdateZoomFactor(_ factor: CGFloat) {
        logger.debug("Delegate: didUpdateZoomFactor called with \(factor)")
        DispatchQueue.main.async {
            self.currentZoomFactor = factor
        }
    }
    
    func didEncounterError(_ error: CameraError) {
        DispatchQueue.main.async {
            self.error = error
        }
    }
}

// MARK: - WCSessionDelegate
// Add delegate methods
extension CameraViewModel: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            wcLogger.error("WCSession activation failed: \(error.localizedDescription)")
            return
        }
        wcLogger.info("WCSession activation completed with state: \(activationState.rawValue)")
        // Send current state when session becomes active
        DispatchQueue.main.async {
            // Make sure the app active state is potentially updated first if possible
            self.sendStateToWatch()
            self.sendLaunchCommandToWatch()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        wcLogger.info("WCSession did become inactive.")
        // iOS only: Can attempt reactivation or wait for sessionDidDeactivate
    }

    func sessionDidDeactivate(_ session: WCSession) {
        wcLogger.info("WCSession did deactivate.")
        // iOS only: Reactivate the session to ensure connectivity.
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        // Handle incoming message on the main thread
        DispatchQueue.main.async { [weak self] in
            self?.handleWatchMessage(message)
            // Send a reply back to the watch immediately (can be empty)
            replyHandler(["status": "received"])
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        wcLogger.info("Watch reachability changed: \(session.isReachable)")
        if session.isReachable {
            // Send current state when watch becomes reachable
             DispatchQueue.main.async {
                 self.sendStateToWatch()
                 self.sendLaunchCommandToWatch()
             }
        }
    }
}
