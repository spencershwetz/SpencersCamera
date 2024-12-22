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
        setupSession()
        
        // Add observer for Apple Log setting changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppleLogSettingChanged),
            name: .appleLogSettingChanged,
            object: nil
        )
    }
    
    @objc private func handleAppleLogSettingChanged() {
        guard let device = device else { return }
        
        do {
            session.beginConfiguration()
            try device.lockForConfiguration()
            
            // Find appropriate format
            let desiredFormat = device.formats.first(where: { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let description = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                
                if settingsModel.isAppleLogEnabled && settingsModel.isAppleLogSupported {
                    // Look for 10-bit capable format
                    return dimensions.width == 1920 &&
                           dimensions.height == 1080 &&
                           (description == kCMVideoCodecType_HEVC || description == kCMVideoCodecType_AppleProRes422)
                } else {
                    return dimensions.width == 1920 && dimensions.height == 1080
                }
            })
            
            if let format = desiredFormat {
                device.activeFormat = format
                print("Set camera format to: \(format)")
                
                if settingsModel.isAppleLogEnabled && settingsModel.isAppleLogSupported {
                    device.activeColorSpace = .appleLog
                    print("Enabled Apple Log recording")
                } else {
                    device.activeColorSpace = .sRGB
                    print("Disabled Apple Log recording")
                }
            }
            
            device.unlockForConfiguration()
            session.commitConfiguration()
            
        } catch {
            print("Error updating Apple Log setting: \(error)")
            self.error = .configurationFailed
        }
    }
    
    func setupSession() {
        print("Setting up camera session...")
        print("Current session running state: \(session.isRunning)")
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("Failed to get camera device")
            error = .deviceNotFound
            return
        }
        
        self.device = device
        
        do {
            session.beginConfiguration()
            
            session.sessionPreset = .high
            print("Session preset set to: \(session.sessionPreset.rawValue)")
            
            try device.lockForConfiguration()
            
            let desiredFormat = device.formats.first(where: { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                if settingsModel.isAppleLogEnabled && settingsModel.isAppleLogSupported {
                    return dimensions.width == 1920 && 
                           dimensions.height == 1080 && 
                           format.supportedColorSpaces.contains(.appleLog)
                } else {
                    return dimensions.width == 1920 && dimensions.height == 1080
                }
            })
            
            if let format = desiredFormat {
                device.activeFormat = format
                print("Set camera format to: \(format)")
                
                if settingsModel.isAppleLogEnabled && settingsModel.isAppleLogSupported {
                    device.activeColorSpace = .appleLog
                    print("Enabled Apple Log recording")
                }
            } else {
                print("Desired format not found.")
            }
            
            device.videoZoomFactor = device.minAvailableVideoZoomFactor
            
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if device.isExposureModeSupported(.custom) {
                device.exposureMode = .custom
            }
            device.unlockForConfiguration()
            
            let input = try AVCaptureDeviceInput(device: device)
            print("Created camera input")
            
            if session.canAddInput(input) {
                session.addInput(input)
                print("Added camera input to session")
            }
            
            // Setup video output
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
            
            // Print available formats for debugging
            let availableFormats = videoOutput.availableVideoPixelFormatTypes
            print("Available pixel formats: \(availableFormats)")
            
            // Find a supported format that matches our needs
            let supportedFormat = availableFormats.first { format in
                // Try to find 10-bit format if available
                format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
                // Fall back to 8-bit format
                format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            }
            
            guard let pixelFormat = supportedFormat else {
                print("No supported pixel format found")
                error = .setupFailed
                return
            }
            
            print("Using pixel format: \(pixelFormat)")
            
            // Configure video output format
            let videoSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            
            videoOutput.videoSettings = videoSettings
            videoOutput.alwaysDiscardsLateVideoFrames = false
            
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                print("Added video output to session")
                
                // Configure the video connection
                if let connection = videoOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }
                    
                    // Handle video orientation based on iOS version
                    if #available(iOS 17.0, *) {
                        connection.videoRotationAngle = 90 // For portrait
                    } else {
                        connection.videoOrientation = .portrait
                    }
                }
            }
            self.videoOutput = videoOutput
            
            // Setup audio input and output
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
                
                let audioOutput = AVCaptureAudioDataOutput()
                audioOutput.setSampleBufferDelegate(self, queue: audioOutputQueue)
                if session.canAddOutput(audioOutput) {
                    session.addOutput(audioOutput)
                    print("Added audio output to session")
                }
                self.audioOutput = audioOutput
            }
            
            session.commitConfiguration()
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                print("Starting camera session...")
                self.session.startRunning()
                print("Session running state after start: \(self.session.isRunning)")
                
                DispatchQueue.main.async {
                    self.isSessionRunning = self.session.isRunning
                }
            }
        } catch {
            print("Error configuring camera session: \(error)")
            self.error = .setupFailed
            session.commitConfiguration()
        }
    }
    
    func updateWhiteBalance(_ temperature: Float) {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            
            let temperatureAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: temperature,
                tint: 0.0
            )
            
            var gains = device.deviceWhiteBalanceGains(for: temperatureAndTint)
            
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(gains.redGain, maxGain)
            gains.greenGain = min(gains.greenGain, maxGain)
            gains.blueGain = min(gains.blueGain, maxGain)
            
            gains.redGain = max(1.0, gains.redGain)
            gains.greenGain = max(1.0, gains.greenGain)
            gains.blueGain = max(1.0, gains.blueGain)
            
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
            print("Cannot start recording: Recording already in progress or processing")
            return 
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoPath = documentsPath.appendingPathComponent("recording-\(Date().timeIntervalSince1970).mov")
        currentRecordingURL = videoPath
        
        do {
            assetWriter = try AVAssetWriter(url: videoPath, fileType: .mov)
            
            // Configure video input for Apple Log
            var videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: 1920,
                AVVideoHeightKey: 1080
            ]
            
            // Configure pixel buffer attributes first
            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1080,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_2020,
                kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_2020
            ]
            
            if settingsModel.isAppleLogEnabled && settingsModel.isAppleLogSupported {
                // Set color properties for Apple Log
                videoSettings[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                ]
                
                // Set compression properties for 10-bit HEVC
                videoSettings[AVVideoCompressionPropertiesKey] = [
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                    AVVideoAverageBitRateKey: 100_000_000,  // 100 Mbps
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoAllowFrameReorderingKey: true
                ]
                
                print("Configuring 10-bit HEVC with Log settings")
            } else {
                videoSettings[AVVideoCompressionPropertiesKey] = [
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAverageBitRateKey: 10_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 30
                ]
                print("Configuring H264 settings")
            }
            
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true
            
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput!,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
            
            if let videoInput = videoInput,
               assetWriter?.canAdd(videoInput) == true {
                assetWriter?.add(videoInput)
            }
            
            // Configure audio input
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,  // Professional audio sample rate
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256000  // 256 kbps for high quality audio
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
            print("Cannot stop recording: No recording in progress")
            return 
        }
        
        isProcessingRecording = true
        isRecording = false
        
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        
        assetWriter?.finishWriting { [weak self] in
            guard let self = self,
                  let outputURL = self.currentRecordingURL else { return }
            
            self.saveVideoToPhotoLibrary(outputURL)
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
                        print("Video saved successfully to photo library")
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

extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording,
              let assetWriter = assetWriter else { return }
        
        let isVideo = output is AVCaptureVideoDataOutput
        let writerInput = isVideo ? videoInput : audioInput
        
        if assetWriter.status == .unknown {
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        
        if assetWriter.status == .writing,
           let input = writerInput,
           input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output is AVCaptureVideoDataOutput
        print("Dropped \(isVideo ? "video" : "audio") buffer")
    }
} 