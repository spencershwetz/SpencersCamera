import AVFoundation
import Photos
import os.log
import UIKit
import CoreMedia
import CoreImage

protocol RecordingServiceDelegate: AnyObject {
    func didStartRecording()
    func didStopRecording()
    func didFinishSavingVideo(thumbnail: UIImage?)
    func didUpdateProcessingState(_ isProcessing: Bool)
    func didEncounterError(_ error: CameraError)
}

class RecordingService: NSObject {
    private let logger = Logger(subsystem: "com.camera", category: "RecordingService")
    private weak var delegate: RecordingServiceDelegate?
    private var session: AVCaptureSession
    private var device: AVCaptureDevice?
    private var lutManager: LUTManager?
    private var isAppleLogEnabled = false
    private var isBakeInLUTEnabled = true // Default to true to maintain backward compatibility
    
    // Recording properties
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var assetWriterPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var currentRecordingURL: URL?
    private var recordingStartTime: CMTime?
    private var recordingOrientation: CGFloat?
    private var isRecording = false
    private var selectedFrameRate: Double = 30.0
    private var selectedResolution: CameraViewModel.Resolution = .uhd
    private var selectedCodec: CameraViewModel.VideoCodec = .hevc
    private var processingQueue: DispatchQueue
    private var ciContext = CIContext()
    
    // Statistics for debugging
    private var videoFrameCount = 0
    private var audioFrameCount = 0
    private var successfulVideoFrames = 0
    private var failedVideoFrames = 0
    
    init(session: AVCaptureSession, delegate: RecordingServiceDelegate) {
        self.session = session
        self.delegate = delegate
        self.processingQueue = DispatchQueue(
            label: "com.camera.recording",
            qos: .userInitiated,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
        super.init()
    }
    
    func setDevice(_ device: AVCaptureDevice) {
        self.device = device
    }
    
    func setLUTManager(_ lutManager: LUTManager) {
        self.lutManager = lutManager
    }
    
    func setAppleLogEnabled(_ enabled: Bool) {
        self.isAppleLogEnabled = enabled
    }
    
    func setBakeInLUTEnabled(_ enabled: Bool) {
        self.isBakeInLUTEnabled = enabled
        logger.info("Bake in LUT setting changed to: \(enabled)")
    }
    
    func setVideoConfiguration(frameRate: Double, resolution: CameraViewModel.Resolution, codec: CameraViewModel.VideoCodec) {
        self.selectedFrameRate = frameRate
        self.selectedResolution = resolution
        self.selectedCodec = codec
    }
    
    func setupVideoDataOutput() {
        if videoDataOutput == nil {
            videoDataOutput = AVCaptureVideoDataOutput()
            videoDataOutput?.setSampleBufferDelegate(self, queue: processingQueue)
            if session.canAddOutput(videoDataOutput!) {
                session.addOutput(videoDataOutput!)
                logger.info("Added video data output to session")
            } else {
                logger.error("Failed to add video data output to session")
            }
        }
    }
    
    func setupAudioDataOutput() {
        if audioDataOutput == nil {
            audioDataOutput = AVCaptureAudioDataOutput()
            audioDataOutput?.setSampleBufferDelegate(self, queue: processingQueue)
            if session.canAddOutput(audioDataOutput!) {
                session.addOutput(audioDataOutput!)
                logger.info("Added audio data output to session")
            } else {
                logger.error("Failed to add audio data output to session")
            }
        }
    }
    
    func startRecording(orientation: CGFloat) async {
        guard !isRecording else { return }
        
        // Enhanced orientation logging
        let deviceOrientation = await UIDevice.current.orientation
        let activeScene = await MainActor.run {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
        }
        let interfaceOrientation = await MainActor.run { activeScene?.interfaceOrientation }
        
        logger.info("📱 Starting recording request:")
        logger.info("--> Device orientation: \\(deviceOrientation.rawValue) (\\(String(describing: deviceOrientation)))")
        logger.info("--> Interface orientation: \\(interfaceOrientation?.rawValue ?? -1) (\\(String(describing: interfaceOrientation)))")
        logger.info("--> Explicit orientation angle passed: \\(orientation)° (Note: This value is currently ignored)")
        
        // Determine the correct orientation angle for the *recording file*
        let recordingAngle: CGFloat
        if deviceOrientation.isValidInterfaceOrientation {
            // Use device orientation if valid (landscape or portrait)
            recordingAngle = deviceOrientation.videoRotationAngleValue
            logger.info("Using device orientation angle for recording: \\(recordingAngle)° (Source: UIDevice.current.orientation)")
        } else {
            // Fallback to interface orientation if device orientation is invalid (e.g., faceUp, faceDown)
            logger.info("Device orientation (\\(deviceOrientation.rawValue)) is invalid for recording. Falling back to interface orientation.")
            switch interfaceOrientation {
            case .portrait:
                recordingAngle = 90
            case .landscapeLeft: // Device physical left side is down (USB port on right)
                recordingAngle = 0
            case .landscapeRight: // Device physical right side is down (USB port on left)
                recordingAngle = 180
            case .portraitUpsideDown:
                recordingAngle = 270
            case .unknown, nil:
                recordingAngle = 90 // Default to portrait if interface orientation is unknown
                logger.warning("Interface orientation is unknown. Defaulting recording angle to 90°.")
            @unknown default:
                recordingAngle = 90 // Default to portrait for future cases
                logger.warning("Unknown interface orientation (\\(interfaceOrientation?.rawValue ?? -1)). Defaulting recording angle to 90°.")
            }
            logger.info("Using interface orientation angle for recording: \\(recordingAngle)° (Source: UIWindowScene.interfaceOrientation)")
        }
        
        // Store the final chosen orientation for the recording file
        recordingOrientation = recordingAngle
        logger.info("Final recording orientation angle set to: \\(recordingAngle)°")
        
        // Reset counters when starting a new recording
        videoFrameCount = 0
        audioFrameCount = 0
        successfulVideoFrames = 0
        failedVideoFrames = 0
        
        do {
            // Create temporary URL for recording
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "recording_\(Date().timeIntervalSince1970).mov"
            let tempURL = tempDir.appendingPathComponent(fileName)
            currentRecordingURL = tempURL
            
            logger.info("Creating asset writer at \(tempURL.path)")
            
            // Create asset writer
            assetWriter = try AVAssetWriter(url: tempURL, fileType: .mov)
            
            // Get dimensions from current format
            guard let device = device else {
                logger.error("Camera device is nil in startRecording")
                throw CameraError.configurationFailed
            }
            
            // Get active format
            let format = device.activeFormat
            
            // ++ ZOOM LOG ++ 
            let currentDeviceZoom = device.videoZoomFactor
            logger.info("ZOOM_LOG: [Recording Start] Device zoom factor BEFORE writer setup: \\(currentDeviceZoom)")
            // ++ END ZOOM LOG ++

            // Now safely get dimensions
            guard let dimensions = format.dimensions else {
                logger.error("Could not get dimensions from active format: \(format)")
                throw CameraError.configurationFailed
            }
            
            // ++ ZOOM LOG ++ 
            logger.info("ZOOM_LOG: [Recording Start] AssetWriter dimensions being configured: \\(dimensions.width)x\\(dimensions.height) (from activeFormat)")
            // ++ END ZOOM LOG ++

            // Set dimensions based on the native format dimensions
            let videoWidth = dimensions.width
            let videoHeight = dimensions.height
            
            // Configure video settings based on current configuration
            var videoSettings: [String: Any] = [
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight
            ]
            
            if selectedCodec == .proRes {
                videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
            } else {
                videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
                
                // Create a single dictionary for all compression properties
                let compressionProperties: [String: Any] = [
                    AVVideoAverageBitRateKey: selectedCodec.bitrate,
                    AVVideoExpectedSourceFrameRateKey: NSNumber(value: selectedFrameRate),
                    AVVideoMaxKeyFrameIntervalKey: Int(selectedFrameRate), // One keyframe per second
                    AVVideoMaxKeyFrameIntervalDurationKey: 1.0, // Force keyframe every second
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: "HEVC_Main42210_AutoLevel",
                    AVVideoColorPrimariesKey: isAppleLogEnabled ? "ITU_R_2020" : "ITU_R_709_2",
                    AVVideoYCbCrMatrixKey: isAppleLogEnabled ? "ITU_R_2020" : "ITU_R_709_2",
                    "AllowOpenGOP": false,
                    "EncoderID": "com.apple.videotoolbox.videoencoder.hevc.422v2"
                ]
                
                videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties
            }
            
            // Create video input with better buffer handling
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true
            
            // Calculate transform based on the determined recording orientation angle
            let transform: CGAffineTransform
            switch recordingOrientation {
            case 0: // Landscape Left (physical right side down, USB on right)
                transform = .identity
                logger.info("Applying transform: .identity (Landscape Left, 0°)")
            case 90: // Portrait
                transform = CGAffineTransform(rotationAngle: .pi / 2)
                logger.info("Applying transform: 90° rotation (Portrait, 90°)")
            case 180: // Landscape Right (physical left side down, USB on left)
                transform = CGAffineTransform(rotationAngle: .pi)
                logger.info("Applying transform: 180° rotation (Landscape Right, 180°)")
            case 270: // Portrait Upside Down
                transform = CGAffineTransform(rotationAngle: -.pi / 2) // or 3 * .pi / 2
                logger.info("Applying transform: 270° rotation (Portrait Upside Down, 270°)")
            default:
                transform = CGAffineTransform(rotationAngle: .pi / 2) // Default to portrait
                logger.warning("Unexpected recordingOrientation \\(recordingOrientation). Defaulting transform to Portrait (90° rotation).")
            }
            assetWriterInput?.transform = transform
            
            logger.info("Created asset writer input with settings: \(videoSettings)")
            
            // Configure audio settings
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            
            // Create audio input
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            
            // Create pixel buffer adaptor with appropriate format
            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            
            assetWriterPixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: assetWriterInput!,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
            
            // Add inputs to writer
            if assetWriter!.canAdd(assetWriterInput!) {
                assetWriter!.add(assetWriterInput!)
                logger.info("Successfully added video input to asset writer.")
            } else {
                logger.error("Could not add video input to asset writer: \\(error.localizedDescription)")
                assetWriter = nil
                delegate?.didEncounterError(.custom(message: "Failed to add video input: \\(error.localizedDescription)"))
                return
            }
            
            if assetWriter!.canAdd(audioInput) {
                assetWriter!.add(audioInput)
                logger.info("Successfully added audio input to asset writer.")
            } else {
                logger.error("Could not add audio input to asset writer: \\(error.localizedDescription)")
                assetWriter = nil
                delegate?.didEncounterError(.custom(message: "Failed to add audio input: \\(error.localizedDescription)"))
                return
            }
            
            // Ensure video and audio outputs are configured
            setupVideoDataOutput()
            setupAudioDataOutput()
            
            // Start writing
            recordingStartTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000000)
            assetWriter!.startWriting()
            assetWriter!.startSession(atSourceTime: self.recordingStartTime!)
            
            logger.info("Started asset writer session at time: \(self.recordingStartTime!.seconds)")
            
            isRecording = true
            delegate?.didStartRecording()
            
            logger.info("Recording started successfully at URL: \\(tempURL.path)")
            logger.info("Recording settings - Resolution: \(videoWidth)x\(videoHeight), Codec: \(self.selectedCodec == .proRes ? "ProRes 422 HQ" : "HEVC"), Frame Rate: \(self.selectedFrameRate)")
            
        } catch {
            delegate?.didEncounterError(.recordingFailed)
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() async {
        guard isRecording else { return }
        
        // Clear stored recording orientation
        recordingOrientation = nil
        logger.info("Cleared recording orientation")
        
        logger.info("Finalizing video with \(self.videoFrameCount) frames (\(self.successfulVideoFrames) successful, \(self.failedVideoFrames) failed)")
        
        await MainActor.run {
            delegate?.didUpdateProcessingState(true)
        }
        
        // Mark all inputs as finished
        assetWriterInput?.markAsFinished()
        logger.info("Marked asset writer inputs as finished")
        
        // Wait for asset writer to finish
        if let assetWriter = assetWriter {
            logger.info("Waiting for asset writer to finish writing...")
            await assetWriter.finishWriting()
            logger.info("Asset writer finished with status: \(assetWriter.status.rawValue)")
            
            if let error = assetWriter.error {
                logger.error("Asset writer error: \(error.localizedDescription)")
            }
        }
        
        // Clean up recording resources
        if let videoDataOutput = videoDataOutput {
            session.removeOutput(videoDataOutput)
            self.videoDataOutput = nil
            logger.info("Removed video data output from session")
        }
        
        if let audioDataOutput = audioDataOutput {
            session.removeOutput(audioDataOutput)
            self.audioDataOutput = nil
            logger.info("Removed audio data output from session")
        }
        
        // Reset recording state
        isRecording = false
        delegate?.didStopRecording()
        recordingStartTime = nil
        
        // Save to photo library if we have a valid recording
        if let outputURL = currentRecordingURL {
            logger.info("Saving video to photo library: \(outputURL.path)")
            
            // Generate thumbnail before saving
            let thumbnail = await generateThumbnail(from: outputURL)
            
            // Save the video
            await saveToPhotoLibrary(outputURL, thumbnail: thumbnail)
        }
        
        // Clean up
        assetWriter = nil
        assetWriterInput = nil
        assetWriterPixelBufferAdaptor = nil
        currentRecordingURL = nil
        
        await MainActor.run {
            delegate?.didUpdateProcessingState(false)
        }
        
        logger.info("Recording session completed")
    }
    
    private func saveToPhotoLibrary(_ outputURL: URL, thumbnail: UIImage?) async {
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized else {
                await MainActor.run {
                    delegate?.didEncounterError(.savingFailed)
                    logger.error("Photo library access denied")
                }
                return
            }
            
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .video, fileURL: outputURL, options: options)
            }
            
            await MainActor.run {
                logger.info("Video saved to photo library")
                delegate?.didFinishSavingVideo(thumbnail: thumbnail)
            }
        } catch {
            await MainActor.run {
                logger.error("Error saving video: \(error.localizedDescription)")
                delegate?.didEncounterError(.savingFailed)
            }
        }
    }
    
    private func generateThumbnail(from videoURL: URL) async -> UIImage? {
        let asset = AVURLAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        // Get thumbnail from first frame
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        
        do {
            let cgImage = try await imageGenerator.image(at: time).image
            return UIImage(cgImage: cgImage)
        } catch {
            logger.error("Error generating thumbnail: \(error.localizedDescription)")
            return nil
        }
    }
    
    // Process image with LUT filter if available
    func applyLUT(to image: CIImage) -> CIImage? {
        guard let lutFilter = lutManager?.currentLUTFilter else {
            return image
        }
        
        lutFilter.setValue(image, forKey: kCIInputImageKey)
        return lutFilter.outputImage
    }
    
    // Helper method for creating pixel buffers from CIImage
    private func createPixelBuffer(from ciImage: CIImage, with template: CVPixelBuffer) -> CVPixelBuffer? {
        var newPixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,
                           CVPixelBufferGetWidth(template),
                           CVPixelBufferGetHeight(template),
                           CVPixelBufferGetPixelFormatType(template),
                           [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                           &newPixelBuffer)
        
        guard let outputBuffer = newPixelBuffer else {
            logger.warning("Failed to create pixel buffer from CI image")
            return nil
        }
        
        ciContext.render(ciImage, to: outputBuffer)
        return outputBuffer
    }
    
    // Helper method for creating sample buffers
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
            logger.warning("Failed to create sample buffer: \(status)")
            return nil
        }
        
        return sampleBuffer
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate

extension RecordingService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording,
              let assetWriter = assetWriter,
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
                logger.debug("Processing video frame #\(self.videoFrameCount), writer status: \(assetWriter.status.rawValue)")
            }
            
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                if isBakeInLUTEnabled, let lutManager = lutManager, lutManager.currentLUTFilter != nil {
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    if let processedImage = applyLUT(to: ciImage),
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
                                logger.debug("Successfully appended processed frame #\(self.successfulVideoFrames)")
                            }
                        } else {
                            failedVideoFrames += 1
                            logger.warning("Failed to create format description for processed frame #\(self.videoFrameCount)")
                        }
                    }
                } else {
                    // No LUT processing needed - use original sample buffer directly
                    
                    // ++ ZOOM LOG ++ 
                    let width = CVPixelBufferGetWidth(pixelBuffer)
                    let height = CVPixelBufferGetHeight(pixelBuffer)
                    if shouldLog {
                         logger.debug("ZOOM_LOG: [Recording Pipeline] Received buffer (NO BAKE IN): \\(width)x\\(height) frame #\\(self.videoFrameCount)")
                    }
                    // ++ END ZOOM LOG ++
                    
                    assetWriterInput.append(sampleBuffer)
                    successfulVideoFrames += 1
                    if shouldLog {
                        logger.debug("Successfully appended original frame #\(self.successfulVideoFrames)")
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
                logger.debug("Processed audio frame #\(self.audioFrameCount)")
            }
        }
    }
} 
