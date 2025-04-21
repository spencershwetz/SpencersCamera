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
        // Add didSet observer to re-apply shutter priority if active
        didSet {
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
    }
    
    @Published var selectedResolution: Resolution = .uhd {
        didSet {
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
    private var cameraDeviceService: CameraDeviceService!
    private var videoFormatService: VideoFormatService!
    
    var recordingService: RecordingService!
    
    @Published var lastLensSwitchTimestamp = Date()
    
    // Logger for orientation specific logs
    private let orientationLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraViewModelOrientation")
    
    // Watch Connectivity properties
    private var wcSession: WCSession?
    private let wcLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "WatchConnectivity")
    private var isAppCurrentlyActive = false // Track app active state
    
    // Timer for polling WB
    private var wbPollingTimerCancellable: AnyCancellable?
    private let wbPollingInterval: TimeInterval = 0.5 // Poll every 0.5 seconds
    
    // NEW: Track interruption state
    @Published var isSessionInterrupted: Bool = false
    // NEW: Track if session start is in progress to prevent interference
    @Published var isStartingSession: Bool = false
    
    // MARK: - Session Lifecycle Management (NEW)

    func startSession() {
        // Log initial state
        // Use self. explicitly in logger string interpolation
        // REMOVE verbose entry log
        // logger.info("StartSession: Entered. isRunning=\(self.session.isRunning), isStarting=\(self.isStartingSession), isInterrupted=\(self.session.isInterrupted)")

        guard !session.isRunning else {
            // Keep essential logs
            logger.info("Session start requested but already running.")
            return
        }
        guard !isStartingSession else {
            // Keep essential logs
            logger.info("Session start requested but already in progress.")
            return
        }
        guard !session.isInterrupted else {
            // Keep essential logs
            logger.warning("Session start requested but session is currently interrupted. Waiting for interruption end.")
            if !isSessionInterrupted {
                DispatchQueue.main.async { self.isSessionInterrupted = true; self.status = .unknown }
            }
            return
        }

        // Keep essential logs
        logger.info("Starting AVCaptureSession...")

        DispatchQueue.main.async {
            self.isStartingSession = true
            // REMOVE verbose state set log
            // self.logger.info("StartSession: MainThread - Set isStartingSession = true")
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                print("StartSession: BackgroundThread - self is nil, cannot proceed.")
                return
            }
            
            // REMOVE verbose background entry log
            // self.logger.info("StartSession: BackgroundThread - Entered.")
            
            // --- ADDED: Reconfigure Session --- 
            var reconfigureError: Error? = nil
            self.session.beginConfiguration()
            // REMOVE verbose config log
            // self.logger.info("StartSession: BackgroundThread - Began configuration for reconfigure.")
            do {
                if let setupService = self.cameraSetupService {
                    try setupService.reconfigureSession()
                    // REMOVE verbose reconfig log
                    // self.logger.info("StartSession: BackgroundThread - Reconfiguration successful.")
                } else {
                    self.logger.error("StartSession: BackgroundThread - cameraSetupService is nil, cannot reconfigure.")
                    throw CameraError.setupFailed // Or a different appropriate error
                }
            } catch {
                self.logger.error("StartSession: BackgroundThread - Reconfiguration FAILED: \(error.localizedDescription)")
                reconfigureError = error
            }
            self.session.commitConfiguration()
             // REMOVE verbose config log
            // self.logger.info("StartSession: BackgroundThread - Committed configuration after reconfigure.")
            
            if let error = reconfigureError {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Keep essential logs
                    self.logger.error("StartSession: MainThreadCompletion - Exiting due to reconfiguration failure.")
                    self.isStartingSession = false
                    self.error = .configurationFailed(message: "Failed to reconfigure session: \(error.localizedDescription)")
                    self.status = .failed
                    self.isSessionRunning = false
                }
                return
            }
            // --- END ADDED ---
            

            // --- Pre-start device configuration check ---
            if let currentDevice = self.device {
                do {
                    // REMOVE verbose pre-start log
                    // self.logger.info("StartSession: BackgroundThread - Pre-start: Locking device for configuration check...")
                    try currentDevice.lockForConfiguration()
                    if currentDevice.exposureMode != .continuousAutoExposure && currentDevice.isExposureModeSupported(.continuousAutoExposure) {
                        currentDevice.exposureMode = .continuousAutoExposure
                        // REMOVE verbose pre-start log
                        // self.logger.info("StartSession: BackgroundThread - Pre-start: Ensured exposure mode is continuousAutoExposure.")
                    } else {
                        // REMOVE verbose pre-start log
                        // self.logger.info("StartSession: BackgroundThread - Pre-start: Exposure mode already continuousAutoExposure or not supported.")
                    }
                    currentDevice.unlockForConfiguration()
                    // REMOVE verbose pre-start log
                    // self.logger.info("StartSession: BackgroundThread - Pre-start: Device configuration check complete.")
                } catch {
                    // Keep essential logs
                    self.logger.error("Pre-start: Failed to configure device exposure mode: \(error.localizedDescription)")
                }
            } else {
                 // Keep essential logs
                 self.logger.warning("Pre-start: Cannot check device configuration, device reference is nil.")
            }
            // --- END ADDED ---

            var startError: Error? = nil
            // REMOVE verbose logging variables
            // var sessionWasRunningBeforeStartCall: Bool = self.session.isRunning
            // self.logger.info("StartSession: BackgroundThread - Before startRunning(). isRunning=\(sessionWasRunningBeforeStartCall)")
            do {
                 // Keep essential logs
                 self.logger.info("Attempting session.startRunning()...")
                 try self.session.startRunning()
                 // Keep essential logs
                 self.logger.info("session.startRunning() completed.")
             } catch {
                 self.logger.error("StartSession: BackgroundThread - startRunning() THREW error: \(error.localizedDescription)")
                 startError = error
             }
            // REMOVE verbose logging variable check
            // var sessionIsRunningAfterStartCall: Bool = self.session.isRunning
            // self.logger.info("StartSession: BackgroundThread - After startRunning(). isRunning=\(sessionIsRunningAfterStartCall)")

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { 
                    print("StartSession: MainThreadCompletion - self is nil")
                    return 
                }
                
                let sessionIsRunningOnMain = self.session.isRunning
                // REMOVE verbose state log
                // self.logger.info("StartSession: MainThreadCompletion - Entered. isRunning=\(sessionIsRunningOnMain)")
                self.isStartingSession = false
                // REMOVE verbose state log
                // self.logger.info("StartSession: MainThreadCompletion - Set isStartingSession = false")

                self.isSessionRunning = sessionIsRunningOnMain
                // Keep essential logs
                self.logger.info("AVCaptureSession running state: \(self.isSessionRunning)")

                if !self.isSessionRunning {
                    // Keep essential logs
                    self.logger.error("Failed to start session after returning to foreground. Error: \(startError?.localizedDescription ?? "None thrown, but session not running")")
                    self.error = startError != nil ? .custom(message: "Session start failed: \(startError!.localizedDescription)") : .sessionFailedToStart
                    self.status = .failed
                } else {
                    // Keep essential logs
                    // self.logger.info("StartSession: MainThreadCompletion - SUCCESS.") // Redundant with running state log
                    self.status = .running
                    self.error = nil 
                }
            }
        }
    }

    func stopSession() {
        // REMOVE verbose entry log
        // logger.info("StopSession: Entered. isRunning=\(self.session.isRunning), isStarting=\(self.isStartingSession)")
        
        guard session.isRunning else {
            // Keep essential logs
            logger.info("Session stop requested but not running.")
            return
        }
        
        // Keep essential logs
        logger.info("Stopping AVCaptureSession...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                print("StopSession: BackgroundThread - self is nil, cannot proceed.")
                return
            }
            
            // REMOVE verbose background entry log
            // self.logger.info("StopSession: BackgroundThread - Entered. isRunning=\(self.session.isRunning)")
            
            let wasRunning = self.session.isRunning
            if wasRunning {
                // REMOVE verbose step log
                // self.logger.info("StopSession: BackgroundThread - Removing inputs/outputs before stopping...")
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }
                // REMOVE verbose step log
                // self.logger.info("StopSession: BackgroundThread - Inputs/Outputs removed.")
                
                // REMOVE verbose step log
                // self.logger.info("StopSession: BackgroundThread - Calling stopRunning()...")
                self.session.stopRunning()
                // REMOVE verbose step log
                // self.logger.info("StopSession: BackgroundThread - stopRunning() completed.")
            } else {
                self.logger.warning("StopSession: BackgroundThread - Session was already not running before stopRunning() call.")
            }
             
            // REMOVE verbose state check
            // let isRunningAfter = self.session.isRunning
            // self.logger.info("StopSession: BackgroundThread - After stopRunning(). isRunning=\(isRunningAfter)")

             DispatchQueue.main.async { [weak self] in
                 guard let self = self else { 
                    print("StopSession: MainThreadCompletion - self is nil")
                    return 
                 }
                 // REMOVE verbose state check
                 // let isRunningOnMain = self.session.isRunning
                 // self.logger.info("StopSession: MainThreadCompletion - Entered. isRunning=\(isRunningOnMain)")
                 self.isSessionRunning = false
                 
                 if self.isStartingSession {
                     self.logger.warning("StopSession: MainThreadCompletion - Resetting isStartingSession flag.")
                     self.isStartingSession = false
                 }
                 // Keep essential logs
                 self.logger.info("AVCaptureSession stopped.")
             }
        }
    }

    // MARK: - Initialization (Original)

    override init() {
        super.init()
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
            let settings = SettingsModel()
            if self.isRecording && settings.isFlashlightEnabled {
                self.flashlightManager.isEnabled = true
                self.flashlightManager.intensity = settings.flashlightIntensity
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
            let settings = SettingsModel()
            self.recordingService.setBakeInLUTEnabled(settings.isBakeInLUTEnabled)
        }
        
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
                
                // Set initial Apple Log state based on current color space
                isAppleLogEnabled = device.activeColorSpace == .appleLog
                
                print("Initial Apple Log Enabled state based on activeColorSpace: \(isAppleLogEnabled)")
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

        // ADD: Observe session interruptions
        NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded), name: .AVCaptureSessionInterruptionEnded, object: session)
        // ADD: Observe session runtime errors
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: .AVCaptureSessionRuntimeError, object: session)
    }
    
    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // REMOVE interruption observers
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionInterruptionEnded, object: session)
        // ADD: Remove runtime error observer
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
        
        flashlightManager.cleanup()
    }
    
    private func setupServices() {
        // Initialize services with self as delegate
        // Ensure ExposureService is initialized before CameraSetupService
        exposureService = ExposureService(delegate: self)
        // RecordingService MUST be initialized before CameraSetupService now
        recordingService = RecordingService(session: session, delegate: self)
        recordingService.setMetalFrameProcessor(self.metalFrameProcessor)
        
        // UPDATE: Pass recordingService to CameraSetupService initializer
        cameraSetupService = CameraSetupService(session: session, exposureService: exposureService, recordingService: recordingService, delegate: self)
        
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
        let settings = SettingsModel()

        // Handle auto-locking exposure if enabled
        if settings.isExposureLockEnabledDuringRecording {
            // --- Modification Start ---
            // Store the actual current mode before applying any lock
            previousExposureMode = currentDevice.exposureMode
            if previousExposureMode == .custom {
                previousISO = currentDevice.iso
                previousExposureDuration = currentDevice.exposureDuration
            }
            logger.info("Storing previous exposure state: Mode \(String(describing: self.previousExposureMode))")
            
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
        if settings.isWhiteBalanceLockEnabled {
            logger.info("Auto-locking white balance for recording start.")
            exposureService.updateWhiteBalance(self.whiteBalance)
        }

        // Set the selected LUT TEXTURE onto the METAL processor BEFORE configuring the recording service
        logger.debug("Setting Metal LUT texture for bake-in: \(self.lutManager.currentLUTTexture != nil ? "Available" : "None")")
        recordingService.setLUTTextureForBakeIn(lutManager.currentLUTTexture) // <-- Use new method to set texture

        // Update configuration for recording
        recordingService.setDevice(currentDevice)
        recordingService.setAppleLogEnabled(isAppleLogEnabled)
        recordingService.setBakeInLUTEnabled(settings.isBakeInLUTEnabled)

        // ---> ADD LOGGING HERE <---
        logger.info("DEBUG_FRAMERATE: Configuring RecordingService with selectedFrameRate: \(self.selectedFrameRate)")
        // ---> END LOGGING <---

        recordingService.setVideoConfiguration(
            frameRate: selectedFrameRate,
            resolution: selectedResolution,
            codec: selectedCodec
        )
        
        // Get current orientation angle for recording
        let connectionAngle = session.outputs.compactMap { $0.connection(with: .video) }.first?.videoRotationAngle ?? -1 // Use -1 to indicate not found
        logger.info("Requesting recording start. Current primary video connection angle: \(connectionAngle)° (This is passed but ignored by RecordingService)")

        // Inform the RecordingService about the Apple Log state *before* starting
        recordingService?.setAppleLogEnabled(isAppleLogEnabled)
        
        // Explicitly set the Bake-in LUT state *before* starting recording
        recordingService?.setBakeInLUTEnabled(settings.isBakeInLUTEnabled)
        
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
        let settings = SettingsModel()
        if settings.isExposureLockEnabledDuringRecording, let modeToRestore = self.previousExposureMode {
            logger.info("Recording stopped: Restoring previous exposure state. SP Active: \(self.isShutterPriorityEnabled), Stored Mode: \(String(describing: modeToRestore))")

            // --- Modification Start ---
            if self.isShutterPriorityEnabled {
                // Restore Shutter Priority auto-ISO (if it was locked for recording)
                logger.info("SP is active, unlocking SP exposure after recording.")
                exposureService.unlockShutterPriorityExposureAfterRecording() // Use new service method
            } else {
                // Restore standard lock state (SP was OFF when recording started)
                logger.info("SP is OFF, restoring standard exposure state based on stored mode: \(String(describing: modeToRestore))")
                switch modeToRestore {
                case .continuousAutoExposure:
                    exposureService.setAutoExposureEnabled(true) // This implicitly sets mode to auto
                    self.isExposureLocked = false // Update UI state
                    logger.info("Restored to .continuousAutoExposure.")
                case .custom:
                    // If the stored mode was custom (e.g., manual ISO/Shutter before recording without SP)
                    exposureService.setAutoExposureEnabled(false) // Set to manual mode first
                    self.isExposureLocked = false // Update UI state
                    if let iso = self.previousISO, let duration = self.previousExposureDuration {
                        logger.info("Attempting to restore previous custom ISO: \(iso) and Duration: \(duration.seconds)s")
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
                    logger.warning("Could not restore unknown previous standard exposure mode: \(String(describing: modeToRestore)). Reverting to auto.")
                    exposureService.setAutoExposureEnabled(true)
                    self.isExposureLocked = false
                }
            }
            // --- Modification End ---

            // Clear the stored state regardless of which path was taken
            self.previousExposureMode = nil
            self.previousISO = nil
            self.previousExposureDuration = nil
        } else if settings.isExposureLockEnabledDuringRecording {
             logger.warning("Lock during recording enabled, but no previous exposure mode was stored. Cannot restore.")
        }

        // Notify RotationLockedContainer about recording state change
        NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)

        // Update watch state
        sendStateToWatch()
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
    func didEncounterError(_ error: CameraError) {
        DispatchQueue.main.async {
            self.error = error
        }
    }

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
        guard isAppCurrentlyActive != active else { return } // Avoid redundant updates
        isAppCurrentlyActive = active
        wcLogger.info("iOS App Active State changed: \(active)")
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

        if !self.isShutterPriorityEnabled {
            logger.info("ViewModel: Enabling Shutter Priority with duration \(targetDurationSeconds)s.")
            exposureService.enableShutterPriority(duration: targetDuration)
            self.isShutterPriorityEnabled = true // Update state AFTER calling service
            // ADDED: Ensure standard AE lock UI turns off when SP enables
            if self.isExposureLocked {
                logger.info("SP enabled, turning off manual exposure lock state.")
                self.isExposureLocked = false // This will trigger updateExposureLock, but it's okay here as SP isn't active *yet* in ExposureService
            }
        } else {
            logger.info("ViewModel: Disabling Shutter Priority.")
            exposureService.disableShutterPriority()
            self.isShutterPriorityEnabled = false // Update state AFTER calling service
            // No need to change isExposureLocked state here - leave it as it was before SP was disabled
        }
        // Remove the old logic that directly manipulated isAutoExposureEnabled and updateShutterAngle
    }

    // Add a property to store cancellables if it doesn't exist
    private var cancellables = Set<AnyCancellable>()

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

    // MARK: - Session Interruption Handling (NEW)

    @objc private func sessionWasInterrupted(notification: Notification) {
        logger.warning("AVCaptureSession was interrupted.")
        guard let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) else {
            logger.warning("Interruption notification missing reason.")
            return
        }
        logger.warning("Interruption reason: \(reason.description)")

        DispatchQueue.main.async {
            self.isSessionInterrupted = true
            self.isSessionRunning = false // Session is not running when interrupted
            self.status = .unknown // Or a new .interrupted status if needed
            // Stop polling WB etc.
            self.stopPollingWhiteBalance()
        }
        
        // If interruption is due to audio activation, might need specific handling?
        // For now, just log.
        if reason == .audioDeviceInUseByAnotherClient || reason == .videoDeviceInUseByAnotherClient {
            logger.warning("Interruption due to device conflict.")
        } else if reason == .videoDeviceNotAvailableInBackground {
            logger.info("Interruption due to video device unavailable in background.")
        }
    }

    @objc private func sessionInterruptionEnded(notification: Notification) {
        logger.info("AVCaptureSession interruption ended.")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isSessionInterrupted = false
            // Attempt to restart the session only if the app is currently active
            if self.isAppCurrentlyActive {
                self.logger.info("App is active, attempting to restart session after interruption ended.")
                self.startSession() // Try starting the session again
            } else {
                self.logger.info("App is not active, deferring session restart until app becomes active.")
            }
        }
    }
    
    // ADD: Runtime Error Handler
    @objc private func sessionRuntimeError(notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            logger.error("AVCaptureSessionRuntimeError received, but no AVError found in userInfo: \(notification.userInfo ?? [:])")
            return
        }

        logger.error("AVCaptureSessionRuntimeError: Code=\(error.code.rawValue), Description=\(error.localizedDescription)")
        logger.error("UserInfo: \(error.userInfo)")

        // Attempt to map to CameraError or handle specific codes if needed
        let cameraError: CameraError
        switch error.code {
        case .mediaServicesWereReset:
            cameraError = .mediaServicesWereReset
            // Attempting session restart might be appropriate here, but needs careful handling
            // to avoid loops. For now, just report.
            logger.warning("Media services were reset. Session restart might be needed after reconfiguration.")
        case .sessionNotRunning:
             cameraError = .sessionFailedToStart // Or a more specific error
             logger.error("Runtime error indicates session is not running.")
        default:
            cameraError = .sessionRuntimeError(error)
        }

        // Update the UI on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.error = cameraError
            self.status = .failed // Set status to failed on runtime error
            self.isSessionRunning = false // Ensure state reflects the error
        }
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
    
    func didUpdateCurrentLens(_ lens: CameraLens) {
        logger.debug("🔄 Delegate: didUpdateCurrentLens called with \(lens.rawValue)x")
        // Update properties on the main thread
        DispatchQueue.main.async {
            self.currentLens = lens
            self.lastLensSwitchTimestamp = Date() // Trigger preview update
            self.logger.debug("🔄 Delegate: Updated currentLens to \(lens.rawValue)x and lastLensSwitchTimestamp.")
            
            // REMOVED: Re-applying exposure lock logic (now handled by CameraDeviceService)
            /*
            if self.isExposureLocked {
                // Log the device name from the exposureService before attempting the lock
                let deviceName = self.exposureService?.getCurrentDeviceName() ?? "Unknown"
                self.logger.info("🔄 [didUpdateCurrentLens] Re-applying exposure lock for device: \(deviceName)")
                self.exposureService?.setExposureLock(locked: true)
            }
            */
        }
    }
    
    func didUpdateZoomFactor(_ factor: CGFloat) {
        logger.debug("Delegate: didUpdateZoomFactor called with \(factor)")
        DispatchQueue.main.async {
            self.currentZoomFactor = factor
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

// Add description for InterruptionReason
extension AVCaptureSession.InterruptionReason {
    var description: String {
        switch self {
        case .videoDeviceNotAvailableInBackground:
            return "Video device not available in background"
        case .audioDeviceInUseByAnotherClient:
            return "Audio device in use by another client"
        case .videoDeviceInUseByAnotherClient:
            return "Video device in use by another client"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "Video device not available with multiple foreground apps"
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "Video device not available due to system pressure"
        @unknown default:
            return "Unknown reason"
        }
    }
}

