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
        
        // Listen for Apple Log setting changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppleLogSettingChanged),
            name: .appleLogSettingChanged,
            object: nil
        )
    }
    
    private func findBestAppleLogFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        return device.formats.first { format in
            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            let codecType = CMFormatDescriptionGetMediaSubType(desc)
            
            // Look for 4K ProRes format with Apple Log support
            let is4K = (dimensions.width == 3840 && dimensions.height == 2160)
            let isProRes = (codecType == 2016686642) // x422 codec
            let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
            
            return is4K && isProRes && hasAppleLog
        }
    }
    
    @objc private func handleAppleLogSettingChanged() {
        guard let device = device else { return }
        
        do {
            // Stop the session before reconfiguring
            session.stopRunning()
            
            session.beginConfiguration()
            try device.lockForConfiguration()
            
            if settingsModel.isAppleLogEnabled {
                if let format = findBestAppleLogFormat(device) {
                    device.activeFormat = format
                    device.activeColorSpace = .appleLog
                    print("Enabled Apple Log in 4K ProRes format: \(format)")
                } else {
                    print("No suitable Apple Log format found")
                }
            } else {
                // Reset to standard format
                device.activeColorSpace = .sRGB
                print("Disabled Apple Log")
            }
            
            device.unlockForConfiguration()
            session.commitConfiguration()
            
            // Restart the session
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
                
                DispatchQueue.main.async {
                    self?.isSessionRunning = self?.session.isRunning ?? false
                }
            }
            
        } catch {
            print("Error updating Apple Log setting: \(error)")
            self.error = .configurationFailed
            
            // Make sure to restart the session even if there's an error
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
                
                DispatchQueue.main.async {
                    self?.isSessionRunning = self?.session.isRunning ?? false
                }
            }
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
        
        // Debug print for Apple Log support
        print("Device formats:")
        device.formats.forEach { format in
            let colorSpaces = format.supportedColorSpaces.map { $0.rawValue }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let codecType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            print("""
                Format: \(format)
                - Dimensions: \(dimensions.width)x\(dimensions.height)
                - Codec: \(codecType)
                - Supports Apple Log: \(colorSpaces.contains(AVCaptureColorSpace.appleLog.rawValue))
                - Supported Color Spaces: \(colorSpaces)
                - HDR: \(format.isVideoHDRSupported)
                ----------------
                """)
        }
        
        self.device = device
        
        do {
            session.beginConfiguration()
            session.sessionPreset = .high
            print("Session preset set to: \(session.sessionPreset.rawValue)")
            
            try device.lockForConfiguration()
            
            // Same logic in initial setup: search 4K ProRes + Apple Log
            let proResFormat = device.formats.first { format in
                let desc = format.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                let codecType  = CMFormatDescriptionGetMediaSubType(desc)
                
                let is4K = (dimensions.width == 3840 && dimensions.height == 2160)
                let isProRes = (codecType == kCMVideoCodecType_AppleProRes422)
                let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
                
                return is4K && isProRes && hasAppleLog
            }
            
            if let format = proResFormat,
               settingsModel.isAppleLogEnabled && settingsModel.isAppleLogSupported {
                
                device.activeFormat = format
                device.activeColorSpace = .appleLog
                print("Enabled Apple Log in 4K ProRes => \(format)")
            } else {
                print("No matching 4K ProRes + Apple Log format found, or Apple Log not enabled. Using default format => \(device.activeFormat)")
            }
            
            device.videoZoomFactor = device.minAvailableVideoZoomFactor
            
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if device.isExposureModeSupported(.custom) {
                device.exposureMode = .custom
            }
            device.unlockForConfiguration()
            
            // Now add camera input
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                print("Added camera input to session")
            }
            
            // Video output
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
            
            // Use 8-bit or 10-bit YUV
            let availableFormats = videoOutput.availableVideoPixelFormatTypes
            print("Available pixel formats: \(availableFormats)")
            
            let chosenPixelFormat = availableFormats.first { fmt in
                // 10-bit or 8-bit YUV
                fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
                fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  ||
                fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            }
            
            guard let pixelFormat = chosenPixelFormat else {
                print("No supported pixel format found")
                error = .setupFailed
                session.commitConfiguration()
                return
            }
            
            print("Using pixel format: \(pixelFormat)")
            let videoSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            
            videoOutput.videoSettings = videoSettings
            videoOutput.alwaysDiscardsLateVideoFrames = false
            
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                print("Added video output to session")
                
                if let connection = videoOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }
                    if #available(iOS 17.0, *) {
                        connection.videoRotationAngle = 90
                    } else {
                        connection.videoOrientation = .portrait
                    }
                }
            }
            self.videoOutput = videoOutput
            
            // Audio
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
            
            // ProRes with Apple Log
            var videoSettings: [String: Any] = [
                AVVideoCodecKey: kCMVideoCodecType_AppleProRes422,
                AVVideoWidthKey: 3840,
                AVVideoHeightKey: 2160
            ]
            
            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: 3840,
                kCVPixelBufferHeightKey as String: 2160,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            
            if settingsModel.isAppleLogEnabled && settingsModel.isAppleLogSupported {
                // Set color properties for Apple Log
                videoSettings[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                ]
                print("Configuring 4K ProRes with Apple Log")
            } else {
                print("Configuring 4K ProRes (No Log)")
            }
            
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true
            
            let _ = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput!,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
            
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
            print("Starting 4K ProRes recording to: \(videoPath)")
            
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
                        print("ProRes video saved to photo library")
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
              let assetWriter = assetWriter else { return }
        
        let writerInput = (output is AVCaptureVideoDataOutput) ? videoInput : audioInput
        
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
    
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let isVideo = output is AVCaptureVideoDataOutput
        print("Dropped \(isVideo ? "video" : "audio") buffer")
    }
}
