import AVFoundation
import SwiftUI
import Photos
import VideoToolbox
import CoreVideo
import os.log
import CoreImage
import UIKit
import CoreMedia
import WatchConnectivity

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

class CameraViewModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, CameraSetupServiceDelegate {
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
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            
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
    
    @Published var isAppleLogEnabled = true {
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
            
            let logEnabled = self.isAppleLogEnabled
            let currentLensVal = self.currentLens.rawValue
            let formatService = self.videoFormatService
            let deviceService = self.cameraDeviceService
            let logger = self.logger

            Task {
                logger.info("🚀 Starting Task to configure Apple Log to \(logEnabled) for lens: \(currentLensVal)x")
                do {
                    formatService?.setAppleLogEnabled(logEnabled)
                    
                    if logEnabled {
                        logger.info("🎥 Calling videoFormatService.configureAppleLog() to prepare device...")
                        guard let formatService = formatService else { throw CameraError.setupFailed }
                        try await formatService.configureAppleLog()
                        logger.info("✅ Successfully completed configureAppleLog() device preparation.")
                    } else {
                        logger.info("🎥 Calling videoFormatService.resetAppleLog() to prepare device...")
                        guard let formatService = formatService else { throw CameraError.setupFailed }
                        try await formatService.resetAppleLog()
                        logger.info("✅ Successfully completed resetAppleLog() device preparation.")
                    }
                    
                    logger.info("🔄 Calling cameraDeviceService.reconfigureSessionForCurrentDevice() to apply changes...")
                    guard let deviceService = deviceService else { throw CameraError.setupFailed }
                    try await deviceService.reconfigureSessionForCurrentDevice()
                    logger.info("✅ Successfully completed reconfigureSessionForCurrentDevice().")

                    logger.info("🏁 Finished Task for Apple Log configuration (enabled: \(logEnabled)) successfully.")
                } catch let error as CameraError {
                    logger.error("❌ Task failed during Apple Log configuration/reconfiguration: \(error.description)")
                    Task { @MainActor in
                        self.error = error
                    }
                } catch {
                    logger.error("❌ Task failed during Apple Log configuration/reconfiguration with unknown error: \(error.localizedDescription)")
                    let wrappedError = CameraError.configurationFailed(message: "Apple Log setup failed: \(error.localizedDescription)")
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
    var previewVideoOutput: AVCaptureVideoDataOutput? // Store the preview output
    
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
    
    @Published var selectedFrameRate: Double = 30.0
    let availableFrameRates: [Double] = [23.976, 24.0, 25.0, 29.97, 30.0]
    
    private var orientationObserver: NSObjectProtocol?
    @Published var currentInterfaceOrientation: UIInterfaceOrientation = .portrait
    
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
    
    @Published var currentTint: Double = 0.0 // Range: -150 to +150
    private let tintRange = (-150.0...150.0)
    
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    @Published var isAutoExposureEnabled: Bool = true {
        didSet {
            exposureService.setAutoExposureEnabled(isAutoExposureEnabled)
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
    
    // Service Instances
    private var cameraSetupService: CameraSetupService!
    private var exposureService: ExposureService!
    private var recordingService: RecordingService!
    private var cameraDeviceService: CameraDeviceService!
    private var videoFormatService: VideoFormatService!
    
    @Published var lastLensSwitchTimestamp = Date()
    
    // Logger for orientation specific logs
    private let orientationLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraViewModelOrientation")
    
    // Watch Connectivity properties
    private var wcSession: WCSession?
    private let wcLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "WatchConnectivity")
    private var isAppCurrentlyActive = false // Track app active state
    
    override init() {
        super.init()
        print("\n=== Camera Initialization ===")
        
        // Initialize services with self as delegate where needed
        self.cameraSetupService = CameraSetupService(session: session, delegate: self)
        self.videoFormatService = VideoFormatService(session: session, delegate: self) 
        // Pass videoFormatService to CameraDeviceService initializer
        self.cameraDeviceService = CameraDeviceService(session: session, videoFormatService: self.videoFormatService, delegate: self)
        self.recordingService = RecordingService(session: session, delegate: self)
        self.exposureService = ExposureService(delegate: self)
        
        // Call setup session and store the preview output
        do {
            self.previewVideoOutput = try cameraSetupService.setupSession()
            if previewVideoOutput == nil {
                 logger.error("Setup session completed but did not return a preview video output.")
                 // Handle error appropriately - perhaps set status to failed
                 self.status = .failed
                 self.error = .setupFailed
            } else {
                 logger.info("✅ Setup session completed successfully, preview output obtained.")
            }
        } catch let error as CameraError {
            logger.error("Camera setup failed: \(error.description)")
            self.error = error
            self.status = .failed
        } catch {
             logger.error("Camera setup failed with unexpected error: \(error.localizedDescription)")
            self.error = .setupFailed // Generic setup error
            self.status = .failed
        }
        
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
        
        // Set default format if device was initialized successfully
        if let initialDevice = self.device {
             defaultFormat = initialDevice.activeFormat
             print("Stored default format: \(defaultFormat?.description ?? "None")")
        } else {
             print("Could not store default format: device was not initialized.")
        }
        
        // Add orientation change observer
        // REMOVED: Orientation is now handled solely within CameraPreviewView
        /*
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                guard let self = self else { return }
                guard !self.isRecording else {
                    self.logger.debug("Orientation changed during recording, skipping connection angle update.")
                    return
                }
                self.applyCurrentOrientationToConnections()
        }
        */
        
        // Set initial shutter angle
        updateShutterAngle(180.0)
        
        print("📱 LUT Loading: No default LUTs will be loaded")
        
        // Setup Watch Connectivity
        setupWatchConnectivity()

        // Send initial state to watch if connected
        // Ensure app active state is set before sending initial context if possible
        // If init runs before scenePhase updates, initial context might show inactive
        sendStateToWatch()

        // ADD: Populate available lenses
        self.availableLenses = CameraLens.availableLenses()
        logger.info("📸 Populated available lenses: \(self.availableLenses.map { $0.rawValue + "x" })")

        // Initial check for Apple Log support
        Task { @MainActor in // Ensure this runs on main thread
            checkAppleLogSupport() // Removed unnecessary await
             // Update initial isAppleLogEnabled based on activeColorSpace AFTER setup
            // This DispatchQueue.main.async might be redundant if already on main from @MainActor Task
            // but kept for safety unless performance becomes an issue.
            DispatchQueue.main.async { 
                if let format = self.device?.activeFormat, format.supportedColorSpaces.contains(.appleLog) {
                    self.isAppleLogEnabled = (self.device?.activeColorSpace == .appleLog)
                     print("Initial Apple Log Enabled state based on activeColorSpace: \(self.isAppleLogEnabled)")
                } else {
                     print("Initial Apple Log Enabled state set to false (not supported or format unavailable).")
                    self.isAppleLogEnabled = false 
                }
            }
        }
         print("=== End Initialization ===\n")
    }
    
    deinit {
        // REMOVED: Orientation observer removal
        /*
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        */
        
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        flashlightManager.cleanup()
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
        currentTint = newValue.clamped(to: tintRange)
        exposureService.updateTint(currentTint, currentWhiteBalance: whiteBalance)
    }
    
    func updateOrientation(_ orientation: UIInterfaceOrientation) {
        guard !isRecording else {
            logger.debug("Interface orientation update skipped during recording.")
            // Still update the published property so UI elements can rotate
            self.currentInterfaceOrientation = orientation
            return
        }
        self.currentInterfaceOrientation = orientation
        
        print("DEBUG: UI Interface orientation updated to: \(orientation.rawValue)")
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
        logger.info("Attempting to start recording...")
        // Use the new public `currentDevice` property
        guard !self.isRecording,
              self.status == .running,
              let currentDevice = self.cameraDeviceService?.currentDevice else { // Use the public currentDevice
            // Log detailed reason for failure
            // Use the public `currentDevice` in the log message as well
            logger.warning("Start recording called but conditions not met. isRecording: \(self.isRecording), status: \(String(describing: self.status)), device: \(self.cameraDeviceService?.currentDevice?.localizedName ?? "nil")")
            return
        }
        
        // Get current settings
        let settings = SettingsModel()
        
        // Update configuration for recording
        recordingService.setDevice(currentDevice)
        recordingService.setLUTManager(lutManager)
        recordingService.setAppleLogEnabled(isAppleLogEnabled)
        recordingService.setBakeInLUTEnabled(settings.isBakeInLUTEnabled)
        recordingService.setVideoConfiguration(
            frameRate: selectedFrameRate,
            resolution: selectedResolution,
            codec: selectedCodec
        )
        
        // Get current orientation angle for recording
        let connectionAngle = session.outputs.compactMap { $0.connection(with: .video) }.first?.videoRotationAngle ?? -1 // Use -1 to indicate not found
        logger.info("Requesting recording start. Current primary video connection angle: \\(connectionAngle)° (This is passed but ignored by RecordingService)")

        // Start recording
        await recordingService.startRecording(orientation: connectionAngle) // Pass angle, though it's recalculated inside

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
        
        // Notify RotationLockedContainer about recording state change
        NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)

        // Update watch state
        sendStateToWatch()

        // Re-apply fixed portrait orientation to connections after recording stops
        // REMOVED: No longer needed as applyCurrentOrientationToConnections is mostly empty and orientation is fixed in PreviewView
        // logger.info("Applying fixed portrait orientation to connections after recording stop.")
        // applyCurrentOrientationToConnections()
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
    
    @objc func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Check if the output is the PREVIEW output
        if output == previewVideoOutput {
            // This is the preview output - MetalCameraPreviewView's coordinator handles this.
            // No action needed here in the ViewModel for preview frames.
        } else {
            // Log if we receive buffers from an unexpected output
            // (RecordingService handles its own outputs internally)
            logger.warning("ViewModel received sample buffer from unexpected output: \(output.description)")
        }
    }

    @objc func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Only log dropped frames from the preview output in the ViewModel
        if output == previewVideoOutput {
             logger.warning("ViewModel detected dropped preview frame")
        } else {
            // RecordingService handles dropped frames for its outputs internally.
            logger.debug("ViewModel detected dropped frame from non-preview output: \(output.description)")
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
    
    private func applyCurrentOrientationToConnections() {
        orientationLogger.debug("--> applyCurrentOrientationToConnections called.")
        // Add logging here to check videoDataOutput
        if self.videoDataOutput == nil {
            orientationLogger.warning("    [applyCurrentOrientation] videoDataOutput is NIL at this point.")
        } else {
            orientationLogger.debug("    [applyCurrentOrientation] videoDataOutput is assigned.")
        }

        // Use UIDevice orientation
        let deviceOrientation = UIDevice.current.orientation
        // REMOVE: let targetAngle: CGFloat

        switch deviceOrientation {
        case .landscapeLeft:
            // REMOVE: targetAngle = 0
            orientationLogger.debug("    Device orientation: Landscape Left -> Target Angle: 0°")
        case .landscapeRight:
            // REMOVE: targetAngle = 180
            orientationLogger.debug("    Device orientation: Landscape Right -> Target Angle: 180°")
        case .portraitUpsideDown:
            // REMOVE: targetAngle = 270
            orientationLogger.debug("    Device orientation: Portrait Upside Down -> Target Angle: 270°")
        case .portrait:
            // REMOVE: targetAngle = 90
            orientationLogger.debug("    Device orientation: Portrait -> Target Angle: 90°")
        default: // Includes .unknown, .faceUp, .faceDown
            // Fallback to portrait if orientation is invalid or face up/down
            // REMOVE: targetAngle = 90
            orientationLogger.debug("    Device orientation: \\(deviceOrientation.rawValue) (Invalid/FaceUp/FaceDown) -> Defaulting to Target Angle: 90°")
        }

        // Apply to Preview Layer connection - REMOVED as previewLayer is private in CustomPreviewView
        // The previewLayer's connection orientation should be managed within CustomPreviewView itself (e.g., via forcePortraitOrientation)
        /* 
        if let previewLayerConnection = (owningView?.viewWithTag(100) as? CameraPreviewView.CustomPreviewView)?.previewLayer.connection {
            ... // Removed logic
        } else {
            orientationLogger.warning("    Could not get PreviewLayer connection.")
        }
        */

        // Apply to Video Data Output connection (The one managed by CameraViewModel/CameraSetupService)
        // REMOVED: This is handled by RecordingService during recording setup.
        /*
        if let videoDataOutputConnection = videoDataOutput?.connection(with: .video) {
            let connectionID = videoDataOutputConnection.description
            let previousAngle = videoDataOutputConnection.videoRotationAngle
            orientationLogger.debug("    Checking VideoDataOutput Connection (\(connectionID)): Current=\(previousAngle)°, Target=\(targetAngle)°")
            if videoDataOutputConnection.isVideoRotationAngleSupported(targetAngle) {
                if videoDataOutputConnection.videoRotationAngle != targetAngle {
                    videoDataOutputConnection.videoRotationAngle = targetAngle
                    orientationLogger.info("    [applyCurrentOrientation] Updated VideoDataOutput connection \(connectionID) rotation angle from \(previousAngle)° to \(targetAngle)°")
                } else {
                     orientationLogger.debug("    Angle \(targetAngle)° already set for VideoDataOutput connection \(connectionID). No change needed.")
                }
            } else {
                orientationLogger.warning("    Angle \(targetAngle)° not supported for VideoDataOutput connection \(connectionID).")
            }
        } else {
             orientationLogger.warning("    Could not get VideoDataOutput connection (ViewModel's instance).") // Clarified which instance
        }
        */

        // Apply to Audio Connection - REMOVED as audioOutput is not directly accessible here
        /* 
        if let audioConnection = audioOutput?.connection(with: .audio) {
            ... // Removed logic
        } else {
             orientationLogger.warning("    Could not get AudioOutput connection.")
        }
        */
        orientationLogger.debug("<-- Finished applyCurrentOrientationToConnections")
    }

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

    // MARK: - CameraSetupServiceDelegate

    func didUpdateSessionStatus(_ status: CameraViewModel.Status) {
        self.status = status
    }

    func didInitializeCamera(device: AVCaptureDevice) {
        self.device = device
         print("�� Set initial device in ViewModel: \(device.localizedName)")
        
        // Pass the initial device to other services that need it using their setDevice methods
        self.cameraDeviceService.setDevice(device)
        self.videoFormatService.setDevice(device)
        self.exposureService.setDevice(device)
        
        // Set the video input for the CameraDeviceService
        if let videoInput = self.cameraSetupService.currentVideoDeviceInput {
            self.cameraDeviceService.setVideoDeviceInput(videoInput)
        } else {
            logger.error("Could not retrieve videoDeviceInput from CameraSetupService after initialization.")
            // Handle this error case appropriately
            // Set the error state directly on the ViewModel
            self.error = .setupFailed 
        }
        
        // Perform initial check for Apple Log support on the main thread
        Task { @MainActor in
            checkAppleLogSupport()
        }
    }

    func didStartRunning(_ isRunning: Bool) {
        self.isSessionRunning = isRunning
         print("Camera session running: \(isRunning)")
    }

    // MARK: - Apple Log Support Check

    @MainActor
    private func checkAppleLogSupport() {
        guard let currentDevice = self.device else {
            logger.warning("Cannot check Apple Log support: device is nil.")
            self.isAppleLogSupported = false
            return
        }
        
        let supported = currentDevice.formats.contains { format in
            format.supportedColorSpaces.contains(.appleLog)
        }
        
        if self.isAppleLogSupported != supported {
            self.isAppleLogSupported = supported
            logger.info("Apple Log Support Updated: \(supported)")
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

// MARK: - Watch Connectivity

extension CameraViewModel: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // TODO: Implement activation handling within CameraViewModel or setup a proper manager
        wcLogger.info("Watch Session activation completed: \(activationState.rawValue), Error: \(error?.localizedDescription ?? "None")")
        // Send initial state upon activation
        if activationState == .activated {
            sendStateToWatch()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        // TODO: Implement inactivation handling if needed
        wcLogger.info("Watch Session became inactive.")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // TODO: Implement deactivation handling; e.g., reactivate session
        wcLogger.info("Watch Session deactivated. Attempting reactivation...")
        session.activate() // Attempt to reactivate
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
         // TODO: Implement reachability handling
         wcLogger.info("Watch Session reachability changed: \(session.isReachable)")
         // Send state if watch becomes reachable
         if session.isReachable {
            sendStateToWatch()
         }
     }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        // Handle messages directly or pass to a handler method
        wcLogger.info("Received direct message: \(message)")
        // Example: Call the existing handler
        Task { @MainActor in
            handleWatchMessage(message)
        }
    }
    
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        // Handle context updates directly or pass to a handler method
        wcLogger.info("Received application context: \(applicationContext)")
        // TODO: Implement context handling if needed
    }
}

// MARK: - ExposureServiceDelegate

extension CameraViewModel: ExposureServiceDelegate {
    func didUpdateWhiteBalance(_ temperature: Float) {
        DispatchQueue.main.async {
            self.whiteBalance = temperature
        }
    }
    
    func didUpdateISO(_ iso: Float) {
        DispatchQueue.main.async {
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
    func didUpdateCurrentLens(_ lens: CameraLens) {
        logger.debug("🔄 Delegate: didUpdateCurrentLens called with \(lens.rawValue)x")
        DispatchQueue.main.async {
            self.currentLens = lens
            self.lastLensSwitchTimestamp = Date() 
            self.logger.debug("🔄 Delegate: Updated currentLens to \(lens.rawValue)x and lastLensSwitchTimestamp.")
        }
    }
    
    func didUpdateZoomFactor(_ factor: CGFloat) {
        logger.debug("Delegate: didUpdateZoomFactor called with \(factor)")
        DispatchQueue.main.async {
            self.currentZoomFactor = factor
        }
    }
}


