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
                        try await videoFormatService.configureAppleLog()
                    } else {
                        print("↩️ Resetting Apple Log...")
                        try await videoFormatService.resetAppleLog()
                    }
                    
                    // Update recording service with new Apple Log setting
                    recordingService.setAppleLogEnabled(isAppleLogEnabled)
                    videoFormatService.setAppleLogEnabled(isAppleLogEnabled)
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
            }
            print("=== End Initialization ===\n")
            
            if let device = device {
                defaultFormat = device.activeFormat
            }
        } catch {
            self.error = .setupFailed
            print("Failed to setup session: \(error)")
        }
        
        // Add orientation change observer
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                guard let self = self,
                      let videoConnection = self.session.outputs.first?.connection(with: .video) else { return }

                self.cameraDeviceService.updateVideoOrientation(for: videoConnection, orientation: self.currentInterfaceOrientation)
        }
        
        // Set initial shutter angle
        updateShutterAngle(180.0)
        
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
    
    private func setupServices() {
        // Initialize services with self as delegate
        cameraSetupService = CameraSetupService(session: session, delegate: self)
        exposureService = ExposureService(delegate: self)
        recordingService = RecordingService(session: session, delegate: self)
        cameraDeviceService = CameraDeviceService(session: session, delegate: self)
        videoFormatService = VideoFormatService(session: session, delegate: self)
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
        self.currentInterfaceOrientation = orientation
        
        if let videoConnection = session.outputs.first?.connection(with: .video) {
            cameraDeviceService.updateVideoOrientation(for: videoConnection, orientation: orientation)
        }
        
        print("DEBUG: UI Interface orientation updated to: \(orientation.rawValue)")
    }
    
    func switchToLens(_ lens: CameraLens) {
        cameraDeviceService.switchToLens(lens)
        
        // Update orientation for all video connections after lens switch
        // This ensures LUT overlay orientation remains correct
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            
            // Update all video connections to maintain proper orientation
            for output in self.session.outputs {
                if let connection = output.connection(with: .video) {
                    self.cameraDeviceService.updateVideoOrientation(for: connection, orientation: self.currentInterfaceOrientation)
                }
            }
        }
    }
    
    func setZoomFactor(_ factor: CGFloat) {
        cameraDeviceService.setZoomFactor(factor, currentLens: currentLens, availableLenses: availableLenses)
    }
    
    @MainActor
    func startRecording() async {
        guard !isRecording, status == .running, let device = self.device else { return }
        
        // Get current settings
        let settings = SettingsModel()
        
        // Update configuration for recording
        recordingService.setDevice(device)
        recordingService.setLUTManager(lutManager)
        recordingService.setAppleLogEnabled(isAppleLogEnabled)
        recordingService.setBakeInLUTEnabled(settings.isBakeInLUTEnabled)
        recordingService.setVideoConfiguration(
            frameRate: selectedFrameRate,
            resolution: selectedResolution,
            codec: selectedCodec
        )
        
        // Lock orientation during recording
        cameraDeviceService.lockOrientationForRecording(true)
        
        // Get current orientation for recording
        let recordingOrientation = session.outputs.first?.connection(with: .video)?.videoRotationAngle ?? 0
        
        // Start recording
        await recordingService.startRecording(orientation: recordingOrientation)
        
        isRecording = true
    }
    
    @MainActor
    func stopRecording() async {
        guard isRecording else { return }
        
        // Stop recording
        await recordingService.stopRecording()
        
        // Unlock orientation after recording
        cameraDeviceService.lockOrientationForRecording(false)
        
        isRecording = false
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
}

// MARK: - VideoFormatServiceDelegate

extension CameraViewModel: VideoFormatServiceDelegate {
    func didUpdateFrameRate(_ frameRate: Double) {
        DispatchQueue.main.async {
            self.selectedFrameRate = frameRate
        }
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
        DispatchQueue.main.async {
            self.currentLens = lens
        }
    }
    
    func didUpdateZoomFactor(_ factor: CGFloat) {
        DispatchQueue.main.async {
            self.currentZoomFactor = factor
        }
    }
}
