import AVFoundation
import SwiftUI
import Photos
import VideoToolbox
import CoreVideo
import os.log
import CoreImage
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
    
    private func setupServices() {
        // Initialize services with self as delegate
        cameraSetupService = CameraSetupService(session: session, delegate: self)
        exposureService = ExposureService(delegate: self)
        recordingService = RecordingService(session: session, delegate: self)
        videoFormatService = VideoFormatService(session: session, delegate: self)
        cameraDeviceService = CameraDeviceService(session: session, videoFormatService: videoFormatService, delegate: self)
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
}

// MARK: - CustomPreviewViewDelegate (NEW)
extension CameraViewModel: CustomPreviewViewDelegate {
    func customPreviewViewDidAddVideoOutput(_ previewView: CameraPreviewView.CustomPreviewView) {
        orientationLogger.debug("Delegate: CustomPreviewView did add video output. Applying initial orientation.")
        // Now that we know the output exists, apply the initial orientation
        // REMOVED: Calls to applyCurrentOrientationToConnections are no longer needed
        // applyCurrentOrientationToConnections()
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
    }
    
    func didStartRunning(_ isRunning: Bool) {
        DispatchQueue.main.async {
            self.isSessionRunning = isRunning
        }
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
        // Update properties on the main thread
        DispatchQueue.main.async {
            self.currentLens = lens
            self.lastLensSwitchTimestamp = Date() // Trigger preview update
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
             }
        }
    }
}

