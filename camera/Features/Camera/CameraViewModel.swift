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
    
    // Turn off Apple Log by default to avoid RenderBox/metallib issues
    @Published var isAppleLogEnabled: Bool = false {
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
    private let settingsModel = SettingsModel()
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
        
        // Check if device supports Apple Log
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
    
    private func findBestAppleLogFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        return device.formats.first { format in
            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            let codecType = CMFormatDescriptionGetMediaSubType(desc)
            
            // Look for 4K ProRes format with Apple Log support
            let is4K = (dimensions.width == 3840 && dimensions.height == 2160)
            let isProRes = (codecType == 2016686642) // 'x422' for ProRes 422
            let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
            let hasHDR = format.isVideoHDRSupported
            
            return is4K && isProRes && hasAppleLog && hasHDR
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
        print("🔄 Changing to: \(isAppleLogEnabled ? "Apple Log" : "sRGB")")
        
        do {
            session.stopRunning()
            print("⏸️ Session stopped for reconfiguration")
            
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
            
            Thread.sleep(forTimeInterval: 0.1)
            session.beginConfiguration()
            
            if isAppleLogEnabled {
                if let format = findBestAppleLogFormat(device) {
                    let frameRateRange = format.videoSupportedFrameRateRanges.first!
                    print("⚙️ Setting frame rate: \(frameRateRange.minFrameRate)-\(frameRateRange.maxFrameRate) fps")
                    
                    try device.lockForConfiguration()
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.maxFrameRate))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.minFrameRate))
                    device.activeFormat = format
                    device.activeColorSpace = .appleLog
                    device.unlockForConfiguration()
                    
                    print("✅ Successfully enabled Apple Log")
                    print("📹 New format: \(format.formatDescription)")
                } else {
                    print("⚠️ No suitable Apple Log format found. Reverting to sRGB.")
                    try device.lockForConfiguration()
                    device.activeColorSpace = .sRGB
                    device.unlockForConfiguration()
                    isAppleLogEnabled = false
                }
            } else {
                try device.lockForConfiguration()
                device.activeColorSpace = .sRGB
                device.unlockForConfiguration()
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
        
        // Configure camera input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                      for: .video,
                                                      position: .back) else {
            error = .cameraUnavailable
            session.commitConfiguration()
            return
        }
        
        self.device = videoDevice
        
        do {
            // By default, do NOT enable Apple Log or 4K ProRes to avoid RenderBox errors
            if isAppleLogEnabled && isAppleLogSupported {
                if let appleLogFormat = findBestAppleLogFormat(videoDevice) {
                    let frameRateRange = appleLogFormat.videoSupportedFrameRateRanges.first!
                    try videoDevice.lockForConfiguration()
                    videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.maxFrameRate))
                    videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.minFrameRate))
                    videoDevice.activeFormat = appleLogFormat
                    videoDevice.activeColorSpace = .appleLog
                    videoDevice.unlockForConfiguration()
                    print("Initial setup: Enabled Apple Log in 4K ProRes format")
                }
            }
            
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }
            
            // Create & add video data output
            videoOutput = setupVideoOutput()
            if let videoOutput = videoOutput, session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
            
            // Create & add audio data output
            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.setSampleBufferDelegate(self, queue: audioOutputQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                self.audioOutput = audioOutput
            }
            
        } catch {
            print("Error setting up camera: \(error)")
            self.error = .setupFailed
            session.commitConfiguration()
            return
        }
        
        session.commitConfiguration()
        
        // Start the session
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = self?.session.isRunning ?? false
            }
        }
    }
    
    private func setupVideoOutput() -> AVCaptureVideoDataOutput {
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        
        // If Apple Log is enabled and supported, attempt a 10-bit format
        if isAppleLogEnabled && isAppleLogSupported {
            let availableFormats = videoOutput.availableVideoPixelFormatTypes
            print("Available video pixel formats: \(availableFormats)")
            
            let preferredFormats: [OSType] = [
                kCVPixelFormatType_422YpCbCr10,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            let format = preferredFormats.first { availableFormats.contains($0) }
            
            guard let pixelFormat = format else {
                print("No suitable pixel format found for Apple Log. Falling back to 8-bit.")
                let fallbackSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
                videoOutput.videoSettings = fallbackSettings
                return videoOutput
            }
            
            let videoSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            videoOutput.videoSettings = videoSettings
            print("Configured video output for Apple Log with format: \(pixelFormat)")
        } else {
            // Standard 8-bit fallback
            let videoSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            videoOutput.videoSettings = videoSettings
            print("Configured video output for standard recording")
        }
        
        videoOutput.alwaysDiscardsLateVideoFrames = false
        return videoOutput
    }
    
    func updateWhiteBalance(_ temperature: Float) {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            let temperatureAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0.0)
            var gains = device.deviceWhiteBalanceGains(for: temperatureAndTint)
            let maxGain = device.maxWhiteBalanceGain
            
            gains.redGain   = min(gains.redGain,   maxGain)
            gains.greenGain = min(gains.greenGain, maxGain)
            gains.blueGain  = min(gains.blueGain,  maxGain)
            gains.redGain   = max(1.0, gains.redGain)
            gains.greenGain = max(1.0, gains.greenGain)
            gains.blueGain  = max(1.0, gains.blueGain)
            
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
        
        do {
            try device.lockForConfiguration()
            let clampedISO = min(max(device.activeFormat.minISO, iso), device.activeFormat.maxISO)
            device.setExposureModeCustom(duration: device.exposureDuration, iso: clampedISO) { _ in }
            device.unlockForConfiguration()
            self.iso = clampedISO
        } catch {
            print("ISO error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    func updateShutterSpeed(_ speed: CMTime) {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: speed, iso: device.iso) { _ in }
            device.unlockForConfiguration()
            
            shutterSpeed = speed
        } catch {
            self.error = .configurationFailed
        }
    }
    
    func startRecording() {
        guard !isRecording && !isProcessingRecording else {
            print("Cannot start recording: Already in progress or processing")
            return
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoPath = documentsPath.appendingPathComponent("recording-\(Date().timeIntervalSince1970).mov")
        currentRecordingURL = videoPath
        
        do {
            assetWriter = try AVAssetWriter(url: videoPath, fileType: .mov)
            
            // To avoid default.metallib issues, do not force Apple Log + 4K ProRes.
            // Use standard H.264 or fallback if Apple Log is known to fail.
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: NSNumber(value: 1920),
                AVVideoHeightKey: NSNumber(value: 1080)
            ]
            
            // Create video input with format hint
            if let currentFormat = device?.activeFormat {
                videoInput = AVAssetWriterInput(mediaType: .video,
                                                outputSettings: videoSettings,
                                                sourceFormatHint: currentFormat.formatDescription)
            } else {
                videoInput = AVAssetWriterInput(mediaType: .video,
                                                outputSettings: videoSettings)
            }
            
            videoInput?.expectsMediaDataInRealTime = true
            if let videoInput = videoInput,
               assetWriter?.canAdd(videoInput) == true {
                assetWriter?.add(videoInput)
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
            if let audioInput = audioInput,
               assetWriter?.canAdd(audioInput) == true {
                assetWriter?.add(audioInput)
            }
            
            isRecording = true
            print("Starting recording to: \(videoPath)")
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
        
        if let videoInput = videoInput {
            finishGroup.enter()
            videoOutputQueue.async {
                videoInput.markAsFinished()
                finishGroup.leave()
            }
        }
        
        if let audioInput = audioInput {
            finishGroup.enter()
            audioOutputQueue.async {
                audioInput.markAsFinished()
                finishGroup.leave()
            }
        }
        
        finishGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            print("Finishing asset writer...")
            
            writer.finishWriting { [weak self] in
                guard let self = self else { return }
                
                if let error = writer.error {
                    print("❌ Error finishing recording: \(error)")
                    DispatchQueue.main.async {
                        self.error = .recordingFailed
                        self.isProcessingRecording = false
                    }
                    return
                }
                
                if let outputURL = self.currentRecordingURL {
                    print("✅ Recording finished successfully")
                    self.saveVideoToPhotoLibrary(outputURL)
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
    
    private func saveVideoToPhotoLibrary(_ outputURL: URL) {
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
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .video, fileURL: outputURL, options: options)
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
        
        let writerInput = (output is AVCaptureVideoDataOutput) ? videoInput : audioInput
        let isVideo = output is AVCaptureVideoDataOutput
        
        switch writer.status {
        case .unknown:
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            // Start session with first video buffer
            if isVideo {
                print("🎥 Starting asset writer session with video buffer")
                writer.startWriting()
                writer.startSession(atSourceTime: timestamp)
                print("📝 Started writing at timestamp: \(timestamp.seconds)")
                
                if let input = writerInput, input.isReadyForMoreMediaData {
                    let success = input.append(sampleBuffer)
                    if !success {
                        print("⚠️ Failed to append first video buffer")
                    }
                }
            }
            
        case .writing:
            if let input = writerInput,
               input.isReadyForMoreMediaData {
                let success = input.append(sampleBuffer)
                if !success {
                    print("⚠️ Failed to append \(isVideo ? "video" : "audio") buffer")
                }
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
            print("️ Asset writer status: \(writer.status.rawValue)")
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let isVideo = output is AVCaptureVideoDataOutput
        print("Dropped \(isVideo ? "video" : "audio") buffer")
    }
}
