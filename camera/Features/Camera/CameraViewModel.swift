import AVFoundation
import SwiftUI
import Photos
import VideoToolbox
import CoreVideo
import os.log
import CoreImage
import CoreMedia
import UIKit // Ensure UIKit is imported

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

class CameraViewModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, CameraSetupServiceDelegate, ExposureServiceDelegate {
    // Add unique ID for logging
    let instanceId = UUID()

    weak var owningView: UIView?
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
    @Published var whiteBalance: Float = 5000
    @Published var iso: Float = 100
    @Published var shutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 60)
    @Published var isRecording = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)
            
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
    
    @Published var lastRecordedVideoThumbnail: UIImage?
    @Published var selectedLUTURL: URL?
    
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
            
            // IMPORTANT: Only configure if the session is actually running.
            // The initial configuration is handled by applyInitialVideoFormat via the delegate.
            guard status == .running, captureMode == .video else {
                print("❌ Cannot configure Apple Log - Status or mode incorrect, or during initial setup.")
                print("Required: status == .running (is: \(status))")
                print("Required: captureMode == .video (is: \(captureMode))")
                print("=== End Apple Log Toggle ===\n") // Log end here if guarding
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
    
    var minISO: Float {
        device?.activeFormat.minISO ?? 50
    }
    var maxISO: Float {
        device?.activeFormat.maxISO ?? 1600
    }
    
    @Published var selectedFrameRate: Double = 30.0
    let availableFrameRates: [Double] = [23.976, 24.0, 25.0, 29.97, 30.0]
    
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
            case .hevc: return 50_000_000
            case .proRes: return 0
            }
        }
    }
    
    @Published var selectedCodec: VideoCodec = .hevc {
        didSet {
            updateVideoConfiguration()
        }
    }
    
    @Published var currentTint: Double = 0.0
    private let tintRange = (-150.0...150.0)
    
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    @Published var isAutoExposureEnabled: Bool = true {
        didSet {
            exposureService.setAutoExposureEnabled(isAutoExposureEnabled)
        }
    }
    
    @Published var lutManager = LUTManager()
    private var ciContext = CIContext()
    
    @Published var currentLens: CameraLens = .wide
    @Published var availableLenses: [CameraLens] = []
    
    @Published var currentZoomFactor: CGFloat = 1.0
    private var lastZoomFactor: CGFloat = 1.0
    
    private var cameraSetupService: CameraSetupService!
    private var exposureService: ExposureService!
    private var recordingService: RecordingService!
    private var cameraDeviceService: CameraDeviceService!
    private var videoFormatService: VideoFormatService!
    
    override init() {
        // Log creation with unique ID
        print("🔶 CameraViewModel.init() - Instance ID: \(instanceId)")
        super.init()
        print("\n=== Camera Initialization ===")
        setupServices()
        
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
            
            updateShutterAngle(180.0)
            print("📱 LUT Loading: No default LUTs will be loaded")
        } catch {
            self.error = .setupFailed
            print("Failed to setup session: \(error)")
        }
        
        updateShutterAngle(180.0)
        print("📱 LUT Loading: No default LUTs will be loaded")
    }
    
    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        NotificationCenter.default.removeObserver(self, name: .bakeInLUTSettingChanged, object: nil)
        
        flashlightManager.cleanup()
    }
    
    private func setupServices() {
        let delegateQueue = DispatchQueue(label: "com.camera.sessionQueue")
        cameraSetupService = CameraSetupService(session: session, 
                                                delegate: self,
                                                captureOutputDelegate: self, 
                                                delegateQueue: delegateQueue)
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
    
    func switchToLens(_ lens: CameraLens) {
        cameraDeviceService.switchToLens(lens)
    }
    
    func setZoomFactor(_ factor: CGFloat) {
        cameraDeviceService.setZoomFactor(factor, currentLens: currentLens, availableLenses: availableLenses)
    }
    
    private func getCurrentVideoTransform() -> CGAffineTransform {
        // Updated to use connectedScenes for iOS 15+ compatibility
        let currentInterfaceOrientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .interfaceOrientation ?? .portrait
        
        let deviceOrientation = UIDevice.current.orientation
        let recordingAngle: CGFloat

        // Prioritize valid device orientation, fallback to interface orientation
        if deviceOrientation.isValidInterfaceOrientation {
            switch deviceOrientation {
                case .portrait: recordingAngle = 90
                case .landscapeLeft: recordingAngle = 0    // USB right
                case .landscapeRight: recordingAngle = 180 // USB left
                case .portraitUpsideDown: recordingAngle = 270
                default: recordingAngle = 90 // Should not happen, but default to portrait
            }
            logger.info("Determined recording angle from device orientation: \(recordingAngle)°")
        } else {
            switch currentInterfaceOrientation {
                case .portrait: recordingAngle = 90
                case .landscapeLeft: recordingAngle = 0    // Matches device landscapeLeft
                case .landscapeRight: recordingAngle = 180 // Matches device landscapeRight
                case .portraitUpsideDown: recordingAngle = 270
                default: recordingAngle = 90 // Default to portrait
            }
             logger.info("Determined recording angle from interface orientation: \(recordingAngle)°")
        }

        // Convert angle to radians for CGAffineTransform
        switch recordingAngle {
            case 90: return CGAffineTransform(rotationAngle: .pi / 2)
            case 180: return CGAffineTransform(rotationAngle: .pi)
            case 0: return .identity
            case 270: return CGAffineTransform(rotationAngle: -.pi / 2) // Or 3 * .pi / 2
            default: return CGAffineTransform(rotationAngle: .pi / 2) // Default portrait
        }
    }

    @MainActor
    func startRecording() async {
        guard !isRecording, status == .running, let device = self.device else { return }

        // Get the current transform *before* calling the service
        let currentTransform = getCurrentVideoTransform()
        logger.info("📸 Starting recording with transform: a=\(currentTransform.a), b=\(currentTransform.b), c=\(currentTransform.c), d=\(currentTransform.d)")


        let settings = SettingsModel()
        recordingService.setDevice(device)
        recordingService.setLUTManager(lutManager)
        recordingService.setAppleLogEnabled(isAppleLogEnabled)
        recordingService.setBakeInLUTEnabled(settings.isBakeInLUTEnabled)
        recordingService.setVideoConfiguration(
            frameRate: selectedFrameRate,
            resolution: selectedResolution,
            codec: selectedCodec
        )

        // CHANGE: Pass the calculated transform to the recording service
        await recordingService.startRecording(transform: currentTransform)

        isRecording = true // Set isRecording *after* the await potentially finishes or throws
    }

    @MainActor
    func stopRecording() async {
        guard isRecording else { return }
        await recordingService.stopRecording()
        
        isRecording = false
    }

    private func updateVideoConfiguration() {
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
    
    func didEncounterError(_ error: CameraError) {
        DispatchQueue.main.async {
            self.error = error
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Forward the call to the recording service IF it's recording
        // This keeps the recording logic encapsulated within RecordingService
        recordingService.processFrame(output: output, sampleBuffer: sampleBuffer, connection: connection)

        // You could also add other real-time processing here if needed, like updating a live histogram, etc.
        // Be mindful of performance on the processingQueue.
    }
    
    // MARK: - CameraSetupServiceDelegate Methods
    func didUpdateSessionStatus(_ status: CameraViewModel.Status) {
        DispatchQueue.main.async {
            self.status = status
            self.isSessionRunning = (status == .running)
        }
    }

    func didInitializeCamera(device: AVCaptureDevice) {
        self.device = device
        exposureService.setDevice(device)
        recordingService.setDevice(device)
        videoFormatService.setDevice(device)
        // Check Apple Log support here if needed
        self.isAppleLogSupported = videoFormatService.isAppleLogSupported(on: device)
        print("✅ Apple Log Support: \(self.isAppleLogSupported)")
    }

    func didStartRunning(_ isRunning: Bool) {
        DispatchQueue.main.async {
            self.isSessionRunning = isRunning
            if isRunning {
                self.status = .running
                // Session is confirmed running, configure initial format
                self.applyInitialVideoFormat()
            } else if self.status != .unauthorized {
                 // If stopping and not due to authorization, set status appropriately
                 self.status = .failed // Or .unknown
            }
        }
    }
    
    // Helper function to apply initial format after session starts
    private func applyInitialVideoFormat() {
        print("Applying initial video format settings...")
        // Ensure this runs after a brief delay to let preview layer attach if necessary
        Task {
             try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second delay
             
             if self.isAppleLogEnabled {
                 print("🎥 Configuring initial Apple Log format...")
                 do {
                     try await videoFormatService.configureAppleLog()
                     recordingService.setAppleLogEnabled(self.isAppleLogEnabled)
                     videoFormatService.setAppleLogEnabled(self.isAppleLogEnabled)
                     print("✅ Initial Apple Log configured.")
                 } catch {
                     await MainActor.run {
                         self.error = .configurationFailed
                     }
                     logger.error("Failed to configure initial Apple Log: \(error.localizedDescription)")
                     print("❌ Initial Apple Log configuration failed: \(error)")
                 }
             } else {
                  // Handle case where default is not Apple Log if needed
                  print("ℹ️ Initial format is not Apple Log.")
             }
        }
    }

    // MARK: - ExposureServiceDelegate Methods (Required Implementations)
    func didUpdateWhiteBalance(_ temperature: Float) {
        DispatchQueue.main.async {
            self.whiteBalance = temperature
            // Optionally update tint if needed based on temperature/gains
            print("Delegate: White Balance Updated to \(temperature)K")
        }
    }
    
    func didUpdateISO(_ iso: Float) {
        DispatchQueue.main.async {
            self.iso = iso
            print("Delegate: ISO Updated to \(iso)")
        }
    }
    
    func didUpdateShutterSpeed(_ speed: CMTime) {
        DispatchQueue.main.async {
            self.shutterSpeed = speed
            // print("Delegate: Shutter Speed Updated to \(speed.timescale)/\(speed.value)")
        }
    }
    // Note: didEncounterError is already handled by the CameraSetupServiceDelegate conformance, assuming errors are channeled there.
    // If ExposureService needs distinct error handling, add its didEncounterError implementation here.

    // MARK: - Lens Control
}

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

extension CameraViewModel: RecordingServiceDelegate {
    func didStartRecording() {
    }
    
    func didStopRecording() {
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
