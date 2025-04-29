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
    
    init(settingsModel: SettingsModel = SettingsModel()) {
        self.settingsModel = settingsModel
        
        // Initialize isAppleLogEnabled with the persisted value from settingsModel
        self.isAppleLogEnabled = settingsModel.isAppleLogEnabled
        self.selectedResolution = settingsModel.selectedResolution
        self.selectedCodec = settingsModel.selectedCodec
        self.selectedFrameRate = settingsModel.selectedFrameRate
        
        super.init()
        // Log ViewModel initialization
        logger.info("[LIFECYCLE] CameraViewModel initializing...")
        print("\n=== Camera Initialization ===")
        
        // Initialize services
        setupServices()
        
        // Add observer for flashlight settings changes
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .flashlightSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.isRecording && self.settingsModel.isFlashlightEnabled {
                self.flashlightManager.isEnabled = true
                self.flashlightManager.intensity = self.settingsModel.flashlightIntensity
            } else {
                self.flashlightManager.isEnabled = false
            }
        }
        
        // Add observer for bake in LUT setting changes
        NotificationCenter.default.addObserver(
            forName: .bakeInLUTSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.recordingService.setBakeInLUTEnabled(self.settingsModel.isBakeInLUTEnabled)
        }
        
        // Add observers for new settings changes
        setupSettingObservers()
        
        do {
            try cameraSetupService.setupSession()
            
            if let device = device {
                print("📊 Device Capabilities:")
                print("- Name: \(device.localizedName)")
                print("- Model ID: \(device.modelID)")
                
                isAppleLogSupported = device.formats.contains { format in
                    format.supportedColorSpaces.contains(.appleLog)
                }
                print("\n✅ Apple Log Support: \(isAppleLogSupported)")
                
                // Don't override the persisted setting with the device's current state
                // Instead, we'll apply our persistent setting to the device
                print("Using persisted Apple Log setting: \(isAppleLogEnabled)")
                
                // Apply Apple Log configuration at startup if needed
                if isAppleLogEnabled && isAppleLogSupported {
                    print("🎨 Applying Apple Log setting during initialization...")
                    // Set Apple Log in the format service
                    videoFormatService.setAppleLogEnabled(isAppleLogEnabled)
                    
                    // Apply the color space setting
                    Task {
                        do {
                            try await videoFormatService.configureAppleLog()
                            print("✅ Successfully applied Apple Log during initialization")
                        } catch {
                            print("❌ Failed to apply Apple Log: \(error)")
                            // Don't throw here to avoid init failure, just log
                        }
                    }
                }
                
                print("=== End Initialization ===\n")
            }
            
            if let device = device {
                defaultFormat = device.activeFormat
            }
        } catch {
            self.error = .setupFailed
            print("Failed to setup session: \(error)")
        }
        
        // Set initial shutter angle
        // updateShutterAngle(180.0)  // temporarily disabled to avoid forcing custom exposure
        
        print("📱 LUT Loading: No default LUTs will be loaded")
        
        // Setup Watch Connectivity
        setupWatchConnectivity()

        // Send initial state to watch if connected
        // Ensure app active state is set before sending initial context if possible
        // If init runs before scenePhase updates, initial context might show inactive
        sendStateToWatch()

        // Observe session running state to start/stop timer
        $isSessionRunning
            .sink { [weak self] isRunning in
                self?.handleSessionRunningStateChange(isRunning)
            }
            .store(in: &cancellables) // Assuming you have a cancellables set

        // Observe session interruptions
        logger.info("[LIFECYCLE] Adding session interruption observers...")
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted,
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionInterruptionEnded(_:)),
                                               name: .AVCaptureSessionInterruptionEnded,
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionRuntimeError(_:)),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: session)

        // Boot-strap DockKit integration (if framework available)
#if canImport(DockKit)
        if #available(iOS 18.0, *) {
            _bootstrapDockKitIfNeeded()
        }
#endif
    }
    
    deinit {
        logger.info("[LIFECYCLE] CameraViewModel DEINIT")
        // Remove all notification observers FIRST
        NotificationCenter.default.removeObserver(self)

        // Explicitly remove device observers BEFORE stopping the session
        // This ensures observers are gone while exposureService is still valid.
        exposureService.removeDeviceObservers()
        logger.info("Explicitly removed ExposureService KVO observers in CameraViewModel deinit")

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
        cameraSetupService = CameraSetupService(session: session, exposureService: exposureService, delegate: self, viewModel: self) // Pass self (ViewModel) here
        recordingService = RecordingService(session: session, delegate: self)
        // recordingService.setLUTProcessor(self.lutProcessor) // REMOVED old processor setting
        recordingService.setMetalFrameProcessor(self.metalFrameProcessor) // ADDED setting Metal processor
        videoFormatService = VideoFormatService(session: session, delegate: self)
        // Pass exposureService to CameraDeviceService initializer
        cameraDeviceService = CameraDeviceService(session: session, videoFormatService: videoFormatService, exposureService: exposureService, delegate: self)
    }
    
    func updateWhiteBalance(_ temperature: Float) {
        exposureService.updateWhiteBalance(temperature)
    }
    
    func updateISO(_ iso: Float) {
        exposureService.updateISO(iso)
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
        // Remove isRecording argument
        
        // Temporarily disable LUT preview during switch to prevent flash
        logger.debug("🔄 Lens switch: Temporarily disabling LUT filter.")
        self.tempLUTFilter = lutManager.currentLUTFilter // Store current filter
        lutManager.currentLUTFilter = nil // Disable LUT in manager (triggers update in PreviewView -> removeLUTOverlay)
        
        // Perform the lens switch
        cameraDeviceService.switchToLens(lens)
        
        // Update the timestamp immediately to trigger orientation update in PreviewView via updateState
        lastLensSwitchTimestamp = Date()
        logger.debug("🔄 Lens switch: Updated lastLensSwitchTimestamp to trigger PreviewView orientation update.")

        // Restore LUT filter immediately after initiating the switch.
        // The PreviewView will handle reapplying it via captureOutput when ready.
        if let storedFilter = self.tempLUTFilter {
            self.logger.debug("🔄 Lens switch: Re-enabling stored LUT filter immediately.")
            self.lutManager.currentLUTFilter = storedFilter
            self.tempLUTFilter = nil // Clear temporary storage
        } else {
             self.logger.debug("🔄 Lens switch: No temporary LUT filter to restore.")
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
            _ = device?.localizedName ?? "nil" // Assign unused deviceName to _
//            logger.trace("Setting camera device: \(deviceName)")
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
        // ADD GUARD: Check if session is already running
        guard !isSessionRunning else {
            logger.info("[SessionControl] Start session requested, but session is already running.")
            // Optionally re-ensure observers are attached here if needed, but be cautious of redundancy
            // Example: self.exposureService.setDevice(self.device)
            return
        }
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // Check again inside async block in case state changed
            guard !self.session.isRunning else {
                self.logger.info("[SessionControl] Session started running between guard check and async block.")
                // Ensure main thread state matches
                DispatchQueue.main.async {
                    if !self.isSessionRunning { self.isSessionRunning = true }
                }
                return
            }
            
            self.logger.info("[SessionControl] Attempting to start session...")
            self.session.startRunning()
            DispatchQueue.main.async {
                // Verify session is ACTUALLY running after startRunning call
                let sessionSuccessfullyStarted = self.session.isRunning
                self.isSessionRunning = sessionSuccessfullyStarted
                self.status = sessionSuccessfullyStarted ? .running : .failed
                
                if sessionSuccessfullyStarted {
                    self.logger.info("[SessionControl] Session started successfully: \(self.isSessionRunning)")
                    // Re-attach KVO observers AFTER session is confirmed running
                    if let currentDevice = self.device {
                        self.logger.info("[SessionControl] Re-attaching ExposureService observers for device: \(currentDevice.localizedName)")
                        self.exposureService.setDevice(currentDevice)
                    } else {
                        self.logger.warning("[SessionControl] Session started but device is nil. Cannot re-attach ExposureService observers.")
                    }
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
        logger.warning("[SessionControl] ExposureService observers removed due to session interruption.") // Added log

        logger.warning("[SessionControl] Session interrupted: \\(notification.userInfo ?? [:])")
        // Check the reason for interruption
        if let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
           let _ = AVCaptureSession.InterruptionReason(rawValue: reasonValue) {
            // Use rawValue for logging instead of description
            logger.warning("[SessionControl] Interruption Reason Raw Value: \\(reasonValue)")
        } else {
            logger.warning("[SessionControl] Interruption Reason: Could not determine reason.")
        }
        
        // Update session state immediately
        DispatchQueue.main.async {
            self.isSessionRunning = false
            // Optionally stop recording if interrupted - Add check if recording
            // if self.isRecording { Task { await self.stopRecording() } } // Consider if this is needed
        }
        // No need to call stopSession() explicitly here? The session is already interrupted by the system.
        // Let's rely on the state update and the interruption ended handler.
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        logger.info("[SessionControl] Session interruption ended. Checking app state...") // Modified log
        // Only attempt restart if the app is currently active
        if isAppCurrentlyActive {
            logger.info("[SessionControl] App is active. Requesting session restart.")
            startSession() // Attempt restart
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

    func updateVideoStabilizationMode(enabled: Bool) { // Updated method
        logger.info("Updating video stabilization mode setting to: \(enabled)")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // Pass the desired state directly
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
        logger.info("Configuring audio input")
        
        // Remove any existing audio inputs
        session.inputs.forEach { input in
            if input.ports.contains(where: { $0.mediaType == .audio }) {
                session.removeInput(input)
            }
        }
        
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
        exposureService.setDevice(device)
        recordingService.setDevice(device)
        cameraDeviceService.setDevice(device)
        videoFormatService.setDevice(device)
        
        // Initialize available lenses
        availableLenses = CameraLens.availableLenses()
        
        // Ensure auto exposure is set on initialization
        do {
            try device.lockForConfiguration()
            if device.exposureMode != .continuousAutoExposure {
                device.exposureMode = .continuousAutoExposure
                logger.info("Initial exposure mode set to continuousAutoExposure")
            }
            device.unlockForConfiguration()
            // Update view model state to match
            self.isAutoExposureEnabled = true
            self.isExposureLocked = false
        } catch {
            logger.error("Failed to set initial exposure mode: \(error.localizedDescription)")
        }
    }
    
    func didStartRunning(_ isRunning: Bool) {
        DispatchQueue.main.async {
            self.isSessionRunning = isRunning
        }
    }
}

// MARK: - ExposureServiceDelegate

extension CameraViewModel: ExposureServiceDelegate {
    func didUpdateWhiteBalance(_ temperature: Float, tint: Float) {
        // Log entry
        self.logger.debug("[TEMP DEBUG] ViewModel Delegate: didUpdateWhiteBalance Entered. Temp: \(temperature), Tint: \(tint)")
        self.whiteBalance = temperature
        self.currentTint = tint
    }
    
    func didUpdateISO(_ iso: Float) {
        DispatchQueue.main.async {
            // self.logger.debug("[ViewModel Delegate] didUpdateISO called with: \(iso)") // REMOVED
            self.iso = iso
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
        // Update properties on the main thread
        DispatchQueue.main.async {
            self.currentLens = lens
            self.lastLensSwitchTimestamp = Date() // Trigger preview update
            self.logger.debug("🔄 Delegate: Updated currentLens to \(lens.rawValue)x and lastLensSwitchTimestamp.")
            
            // FIX: Re-apply exposure lock and shutter priority after lens switch if needed.
            if self.isShutterPriorityEnabled {
                self.logger.info("🔄 [didUpdateCurrentLens] Re-applying Shutter Priority mode after lens switch.")
                // Always recalculate 180° shutter duration for current frame rate
                let frameRate = self.selectedFrameRate > 0 ? self.selectedFrameRate : 24.0 // fallback
                let durationSeconds = 1.0 / (frameRate * 2.0)
                let duration = CMTimeMakeWithSeconds(durationSeconds, preferredTimescale: 1_000_000)
                self.logger.info("🔄 [didUpdateCurrentLens] Calculated 180° shutter duration: \(String(format: "%.5f", durationSeconds))s for frameRate \(frameRate)")
                self.exposureService?.enableShutterPriority(duration: duration)
                if self.isExposureLocked {
                    self.logger.info("🔄 [didUpdateCurrentLens] Scheduling lock of Shutter Priority exposure after lens switch (delayed)")
                    // Add a short delay to ensure device is ready before locking
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self = self else { return }
                        self.logger.info("🔄 [didUpdateCurrentLens] Locking Shutter Priority exposure after lens switch (delayed)")
                        self.exposureService?.lockShutterPriorityExposureForRecording()
                    }
                }
            } else if self.isExposureLocked {
                self.logger.info("🔄 [didUpdateCurrentLens] Re-applying standard AE exposure lock after lens switch.")
                self.exposureService?.setExposureLock(locked: true)
            }
            // End FIX

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
