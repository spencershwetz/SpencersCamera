import AVFoundation
import SwiftUI
import Photos
import VideoToolbox
import CoreVideo

class CameraViewModel: NSObject, ObservableObject {
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
    @Published var isAppleLogEnabled: Bool = true {
        didSet {
            handleAppleLogSettingChanged()
        }
    }
    
    @Published var isAppleLogSupported: Bool = false
    
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
    
    var minISO: Float {
        device?.activeFormat.minISO ?? 50
    }
    var maxISO: Float {
        device?.activeFormat.maxISO ?? 1600
    }
    
    override init() {
        super.init()
        print("\n=== Camera Initialization ===")
        setupSession()
        
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
    
    private func handleAppleLogSettingChanged() {
        guard let device = device else {
            print("❌ No camera device available")
            return
        }
        
        print("\n=== Apple Log State Change ===")
        print("🎥 Current device: \(device.localizedName)")
        print("📊 Current format: \(device.activeFormat.formatDescription)")
        print("🎨 Current color space: \(device.activeColorSpace.rawValue)")
        print("🔄 Changing to: \(isAppleLogEnabled ? "Apple Log (4K ProRes)" : "sRGB")")
        
        do {
            session.stopRunning()
            print("⏸️ Session stopped for reconfiguration")
            
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
            
            Thread.sleep(forTimeInterval: 0.1)
            session.beginConfiguration()
            
            if isAppleLogEnabled, let format = findBestAppleLogFormat(device) {
                let frameRateRange = format.videoSupportedFrameRateRanges.first!
                
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.maxFrameRate))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.minFrameRate))
                device.activeFormat = format
                device.activeColorSpace = .appleLog
                device.unlockForConfiguration()
                
                print("✅ Successfully enabled Apple Log in 4K ProRes")
                print("📹 New format: \(format.formatDescription)")
            } else {
                // fallback to sRGB
                try device.lockForConfiguration()
                device.activeColorSpace = .sRGB
                device.unlockForConfiguration()
                isAppleLogEnabled = false
                print("✅ Reset to sRGB color space")
            }
            
            session.commitConfiguration()
            print("💾 Configuration committed")
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
                print("▶️ Session restarted")
                
                DispatchQueue.main.async {
                    self?.isSessionRunning = self?.session.isRunning ?? false
                    print("📱 UI updated - session running: \(self?.session.isRunning ?? false)")
                }
            }
        } catch {
            print("❌ Error updating Apple Log setting: \(error.localizedDescription)")
            self.error = .configurationFailed
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
                print("🔄 Attempting session recovery")
            }
        }
        
        print("=== End Apple Log State Change ===\n")
    }
    
    private func setupSession() {
        session.beginConfiguration()
        
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                        for: .video,
                                                        position: .back)
        else {
            error = .cameraUnavailable
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
            }
            
            // Audio output
            audioOutput = AVCaptureAudioDataOutput()
            audioOutput?.setSampleBufferDelegate(self, queue: audioOutputQueue)
            if let aOut = audioOutput, session.canAddOutput(aOut) {
                session.addOutput(aOut)
            }
            
        } catch {
            print("Error setting up camera: \(error)")
            self.error = .setupFailed
            session.commitConfiguration()
            return
        }
        
        session.commitConfiguration()
        
        // Start session
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = self?.session.isRunning ?? false
            }
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
            
            var videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.proRes422,
                AVVideoWidthKey: 3840,
                AVVideoHeightKey: 2160
            ]
            
            // FIX: Must specify all three color keys or none at all.
            // Option A (Recommended): Omit entire AVVideoColorPropertiesKey dictionary
            // to let Apple Log pass through naturally:
            /*
            // Remove these lines entirely:
            // videoSettings[AVVideoColorPropertiesKey] = [
            //   // Nothing
            // ]
            */
            
            // Option B (If you must specify color keys):
            // Provide *all three*: Primaries, TransferFunction, YCbCrMatrix
            // Example forcibly using HLG for Apple Log:
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
            } else {
                videoInput = AVAssetWriterInput(mediaType: .video,
                                                outputSettings: videoSettings)
            }
            
            // Correct orientation
            videoInput?.transform = UIDevice.current.orientation.videoTransform
            
            videoInput?.expectsMediaDataInRealTime = true
            if let vIn = videoInput, assetWriter?.canAdd(vIn) == true {
                assetWriter?.add(vIn)
            }
            
            // Audio
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000
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
}

// MARK: - Sample Buffer Delegate
extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording,
              let writer = assetWriter else { return }
        
        let isVideo = (output is AVCaptureVideoDataOutput)
        let writerInput = isVideo ? videoInput : audioInput
        
        switch writer.status {
        case .unknown:
            // Start writing with first video buffer
            if isVideo {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                print("🎥 Starting asset writer session with video buffer")
                writer.startWriting()
                writer.startSession(atSourceTime: pts)
                print("📝 Started writing at timestamp: \(pts.seconds)")
                
                if let wI = writerInput, wI.isReadyForMoreMediaData {
                    _ = wI.append(sampleBuffer)
                }
            }
        case .writing:
            if let wI = writerInput, wI.isReadyForMoreMediaData {
                _ = wI.append(sampleBuffer)
            }
        case .failed:
            print("❌ Asset writer failed: \(writer.error?.localizedDescription ?? "unknown error")")
            DispatchQueue.main.async {
                self.error = .recordingFailed
                self.isRecording = false
                self.isProcessingRecording = false
            }
        case .completed:
            print("✅ Asset writer completed")
        default:
            break
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
            // home button on left
            return CGAffineTransform(rotationAngle: .pi)
        case .portraitUpsideDown:
            return CGAffineTransform(rotationAngle: -.pi / 2)
        case .landscapeLeft:
            // home button on right
            return .identity
        default:
            // portrait or unknown
            return CGAffineTransform(rotationAngle: .pi / 2)
        }
    }
}
