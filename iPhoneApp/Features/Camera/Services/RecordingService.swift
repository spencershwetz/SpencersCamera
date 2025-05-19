import AVFoundation
import Photos
import os.log
import UIKit
import CoreMedia
import CoreImage
import Metal
import CoreLocation

// Add performance logging helper
extension Date {
    static func nowTimestamp() -> Double {
        return CACurrentMediaTime()
    }
}

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
    private var metalFrameProcessor: MetalFrameProcessor?
    private var isAppleLogEnabled = false
    private var isBakeInLUTEnabled = false // Default bake-in to false
    
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
    
    // Statistics for debugging
    private var videoFrameCount = 0
    private var audioFrameCount = 0
    private var successfulVideoFrames = 0
    private var failedVideoFrames = 0
    
    private var locationService = LocationService.shared
    private var recordingLocation: CLLocation?
    
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
        // Only setup audio output now
        setupAudioDataOutput()
        logger.info("REC_PERF: RecordingService initialized with audio output configured.")
    }
    
    func setDevice(_ device: AVCaptureDevice) {
        self.device = device
    }
    
    func setMetalFrameProcessor(_ processor: MetalFrameProcessor?) {
        self.metalFrameProcessor = processor
        logger.info("MetalFrameProcessor instance \(processor != nil ? "set" : "cleared") in RecordingService.")
    }
    
    func setLUTTextureForBakeIn(_ texture: MTLTexture?) {
        self.metalFrameProcessor?.lutTexture = texture
        logger.info("LUT Texture \(texture != nil ? "set" : "cleared") on MetalFrameProcessor for bake-in.")
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
    
    func setupAudioDataOutput() {
        // --- AUDIO OUTPUT DISABLED FOR HAPTIC TEST ---
        /*
        guard audioDataOutput == nil else {
            logger.info("Audio data output already configured.")
            return
        }
        audioDataOutput = AVCaptureAudioDataOutput()
        audioDataOutput?.setSampleBufferDelegate(self, queue: processingQueue)
        if session.canAddOutput(audioDataOutput!) {
            session.addOutput(audioDataOutput!)
            logger.info("Added audio data output to session")
        } else {
            logger.error("Failed to add audio data output to session")
        }
        */
    }
    
    func startRecording(orientation: CGFloat) async {
        guard !isRecording else { return }
        let startTime = Date.nowTimestamp() // START TIMER
        logger.info("REC_PERF: startRecording BEGIN")

        // ---> ADD LOGGING HERE <---
        logger.info("DEBUG_FRAMERATE: RecordingService startRecording called. Internal selectedFrameRate: \\(self.selectedFrameRate)")
        // ---> END LOGGING <---

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
            logger.info("REC_ORIENT: Using device orientation (\\(deviceOrientation.rawValue)) angle for recording: \\(recordingAngle)°") // Enhanced log
        } else {
            // Fallback to interface orientation if device orientation is invalid (e.g., faceUp, faceDown)
            logger.info("REC_ORIENT: Device orientation (\\(deviceOrientation.rawValue)) is invalid for recording. Falling back to interface orientation (\\(interfaceOrientation?.rawValue ?? -1))") // Enhanced log
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
                logger.warning("REC_ORIENT: Interface orientation is unknown. Defaulting recording angle to 90°.") // Enhanced log
            @unknown default:
                recordingAngle = 90 // Default to portrait for future cases
                logger.warning("REC_ORIENT: Unknown interface orientation (\\(interfaceOrientation?.rawValue ?? -1)). Defaulting recording angle to 90°.") // Enhanced log
            }
            logger.info("REC_ORIENT: Using interface orientation angle for recording: \\(recordingAngle)°") // Enhanced log
        }
        
        // Store the final chosen orientation for the recording file
        recordingOrientation = recordingAngle
        logger.info("REC_ORIENT: Final recording orientation angle set to: \\(recordingAngle)°") // Enhanced log
        
        // Reset counters when starting a new recording
        videoFrameCount = 0
        audioFrameCount = 0
        successfulVideoFrames = 0
        failedVideoFrames = 0
        
        do {
            // Create temporary URL for recording
            let tempDir = FileManager.default.temporaryDirectory
            // Use a persistent counter in UserDefaults to mimic native camera naming
            let defaults = UserDefaults.standard
            let counterKey = "spencersCameraVideoFileCounter"
            var fileNumber = defaults.integer(forKey: counterKey)
            fileNumber += 1
            defaults.set(fileNumber, forKey: counterKey)
            let fileName = String(format: "IMG_%04d.MOV", fileNumber)
            let tempURL = tempDir.appendingPathComponent(fileName)
            currentRecordingURL = tempURL
            
            logger.info("REC_PERF: startRecording [\(String(format: "%.3f", Date.nowTimestamp() - startTime))s] Before AVAssetWriter setup") // LOG TIME
            // Create asset writer
            assetWriter = try AVAssetWriter(url: tempURL, fileType: .mov)
            logger.info("REC_PERF: startRecording [\(String(format: "%.3f", Date.nowTimestamp() - startTime))s] After AVAssetWriter setup") // LOG TIME
            
            // Get dimensions from current format
            guard let device = device else {
                logger.error("Camera device is nil in startRecording")
                throw CameraError.configurationFailed
            }
            
            // Get active format
            let format = device.activeFormat
            
            // Now safely get dimensions
            guard let dimensions = format.dimensions else {
                logger.error("Could not get dimensions from active format: \(format)")
                throw CameraError.configurationFailed
            }
            
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
                
                // ---> ADD LOGGING HERE <---
                logger.info("DEBUG_FRAMERATE: Setting AVVideoExpectedSourceFrameRateKey to \\(self.selectedFrameRate)")
                // ---> END LOGGING <---

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
                logger.info("REC_ORIENT: Applying transform: .identity (Landscape Left, 0°)") // Enhanced log
            case 90: // Portrait
                transform = CGAffineTransform(rotationAngle: .pi / 2)
                logger.info("REC_ORIENT: Applying transform: 90° rotation (Portrait, 90°)") // Enhanced log
            case 180: // Landscape Right (physical left side down, USB on left)
                transform = CGAffineTransform(rotationAngle: .pi)
                logger.info("REC_ORIENT: Applying transform: 180° rotation (Landscape Right, 180°)") // Enhanced log
            case 270: // Portrait Upside Down
                transform = CGAffineTransform(rotationAngle: -.pi / 2) // or 3 * .pi / 2
                logger.info("REC_ORIENT: Applying transform: 270° rotation (Portrait Upside Down, 270°)") // Enhanced log
            default:
                transform = CGAffineTransform(rotationAngle: .pi / 2) // Default to portrait
                logger.warning("REC_ORIENT: Unexpected recordingOrientation \\(recordingOrientation). Defaulting transform to Portrait (90° rotation).") // Enhanced log
            }
            assetWriterInput?.transform = transform
            logger.info("REC_ORIENT: Transform applied to AVAssetWriterInput: \\(transform)") // Add log for applied transform
            
            logger.info("Created asset writer input with settings: \(videoSettings)")
            
            // Configure audio settings
            /*
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
            */
            
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
            } else {
                let error = assetWriter!.error ?? NSError(domain: "RecordingService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown error adding video input"]) // Capture or create error
                logger.error("Could not add video input to asset writer: \(error.localizedDescription)")
                assetWriter = nil
                delegate?.didEncounterError(.custom(message: "Failed to add video input: \(error.localizedDescription)"))
                return
            }
            // --- AUDIO INPUT DISABLED FOR HAPTIC TEST ---
            /*
            if assetWriter!.canAdd(audioInput) {
                assetWriter!.add(audioInput)
            } else {
                let error = assetWriter!.error ?? NSError(domain: "RecordingService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown error adding audio input"]) // Capture or create error
                logger.error("Could not add audio input to asset writer: \(error.localizedDescription)")
                assetWriter = nil
                delegate?.didEncounterError(.custom(message: "Failed to add audio input: \(error.localizedDescription)"))
                return
            }
            */
            
            // Ensure video and audio outputs are configured
            // REMOVED: setupVideoDataOutput()
            // REMOVED: setupAudioDataOutput()
            logger.info("REC_PERF: startRecording [\(String(format: "%.3f", Date.nowTimestamp() - startTime))s] After setup outputs (skipped, done in init)") // LOG TIME
            
            // Start writing
            recordingStartTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000000)
            assetWriter!.startWriting()
            assetWriter!.startSession(atSourceTime: self.recordingStartTime!)

            isRecording = true
            delegate?.didStartRecording()
            
            // Start location updates
            locationService.startUpdating()
            recordingLocation = locationService.currentLocation
            
        } catch {
            delegate?.didEncounterError(.recordingFailed)
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() async {
        guard isRecording else { return }
        let stopTime = Date.nowTimestamp()
        
        await MainActor.run {
            self.delegate?.didUpdateProcessingState(true)
        }
        
        // Mark inputs as finished
        self.assetWriterInput?.markAsFinished()
        
        // Stop recording on the processing queue
        if let assetWriter = self.assetWriter {
            // Wait for asset writer to finish
            await assetWriter.finishWriting()
            
            if assetWriter.status == .completed, let recordingURL = self.currentRecordingURL {
                // Add frame count log
                self.logger.info("Video frame statistics: Total=\(self.videoFrameCount), Successful=\(self.successfulVideoFrames), Failed=\(self.failedVideoFrames)")
                self.logger.info("Audio frames processed: \(self.audioFrameCount)")
                
                // Save to photo library
                await self.saveRecordingToPhotoLibrary(recordingURL)
            } else {
                self.logger.error("Failed to write recording: \(assetWriter.error?.localizedDescription ?? "Unknown error")")
                await MainActor.run {
                    self.delegate?.didEncounterError(.recordingFailed)
                }
            }
        }
        
        // Perform cleanup in autoreleasepool
        autoreleasepool {
            // Release asset writer objects
            self.assetWriterInput = nil
            self.assetWriterPixelBufferAdaptor = nil
            self.assetWriter = nil
            
            // Clear recording location
            self.recordingLocation = nil
            
            // Clear temporary URL after saving
            if let url = self.currentRecordingURL {
                do {
                    // Check if file exists before trying to delete
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                        self.logger.info("Removed temporary recording file")
                    }
                } catch {
                    self.logger.error("Failed to remove temporary recording file: \(error.localizedDescription)")
                }
                self.currentRecordingURL = nil
            }
            
            // Reset counters and statistics
            self.videoFrameCount = 0
            self.audioFrameCount = 0
            self.successfulVideoFrames = 0
            self.failedVideoFrames = 0
            
            // Force memory cleanup
            self.logger.info("RecordingService cleanup: Released resources and forced memory cleanup")
        }
        
        // Reset recording state
        self.isRecording = false
        self.recordingStartTime = nil
        self.recordingOrientation = nil
        
        await MainActor.run {
            self.delegate?.didStopRecording()
            self.delegate?.didUpdateProcessingState(false)
        }
        
        self.logger.info("StopRecording process time: \(String(format: "%.3f", Date.nowTimestamp() - stopTime))s")
    }
    
    // Add the new saveRecordingToPhotoLibrary method
    private func saveRecordingToPhotoLibrary(_ url: URL) async {
        logger.info("Saving recording to photo library...")
        
        // Generate thumbnail
        let thumbnail = await generateThumbnail(from: url)
        
        // Save to photo library
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .video, fileURL: url, options: options)
                
                // Add location if available
                if let location = self.recordingLocation {
                    creationRequest.location = location
                    self.logger.info("Adding location metadata: \(location)")
                }
            }
            logger.info("Video saved to photo library successfully")
            
            // Notify delegate on main thread
            await MainActor.run {
                delegate?.didFinishSavingVideo(thumbnail: thumbnail)
            }
        } catch {
            logger.error("Error saving video to photo library: \(error.localizedDescription)")
            await MainActor.run {
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
    
    // Add new method to process sample buffers from CameraViewModel
    func process(sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }
        
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
           CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Video {
            // Process video frame silently
            videoFrameCount += 1
            
            if assetWriter?.status == .unknown {
                let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                recordingStartTime = startTime
                assetWriter?.startWriting()
                assetWriter?.startSession(atSourceTime: startTime)
            }
            
            if assetWriter?.status == .writing {
                if let input = assetWriterInput, input.isReadyForMoreMediaData {
                    // If we have a Metal processor and LUT baking is enabled, process the frame
                    if isBakeInLUTEnabled, let processor = metalFrameProcessor {
                        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                            if let processedBuffer = processor.processFrame(pixelBuffer: pixelBuffer, bakeInLUT: true) {
                                let success = assetWriterPixelBufferAdaptor?.append(processedBuffer, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) ?? false
                                if success {
                                    successfulVideoFrames += 1
                                } else {
                                    failedVideoFrames += 1
                                    logger.error("Failed to append processed video frame")
                                }
                            }
                        }
                    } else {
                        // Direct append without processing
                        let success = input.append(sampleBuffer)
                        if success {
                            successfulVideoFrames += 1
                        } else {
                            failedVideoFrames += 1
                            logger.error("Failed to append video frame")
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Deinitialization
    deinit {
        logger.info("RecordingService DEINIT triggered.")
        // Nil out the delegate for the audioDataOutput it owns to break potential retain cycle
        if let audioOutput = self.audioDataOutput {
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            logger.info("Nilled delegate for RecordingService's internal audioDataOutput.")
            // Optional: Consider removing the audioOutput from the session if RecordingService
            // is solely responsible for its lifecycle and it's not shared/expected elsewhere.
            // self.session.removeOutput(audioOutput)
            // logger.info("Removed RecordingService's internal audioDataOutput from session.")
        }
        // Any other cleanup specific to RecordingService if needed
        logger.info("RecordingService deinitialization complete.")
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate

extension RecordingService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // --- ADD CHECK: Only process if recording --- 
        guard isRecording else {
            return // Ignore frames if not recording
        }
        // --- END CHECK --- 

        _ = Date.nowTimestamp() // START FRAME TIMER
        guard let assetWriter = assetWriter,
              assetWriter.status == .writing else {
            // Added isRecording check above, so this path might be less likely,
            // but keep as safety check for writer status.
            return
        }
        
        // Handle video data
        if output == videoDataOutput,
           let assetWriterInput = assetWriterInput,
           assetWriterInput.isReadyForMoreMediaData {
            
            videoFrameCount += 1
            
            // Process frame silently without logging
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                var pixelBufferToAppend: CVPixelBuffer? = nil
                var isProcessed = false
                
                // Apply LUT via Metal only if bake-in is enabled and processor exists
                if let processor = metalFrameProcessor,
                   let processedPixelBuffer = processor.processFrame(pixelBuffer: pixelBuffer, bakeInLUT: self.isBakeInLUTEnabled) { // Pass the bake-in flag
                    pixelBufferToAppend = processedPixelBuffer
                    isProcessed = true
                } else {
                    // Use original pixel buffer if processing is skipped or fails
                    pixelBufferToAppend = pixelBuffer // Use the original buffer
                    isProcessed = false
                }
                
                // Ensure we have a valid pixel buffer to append
                guard let finalPixelBuffer = pixelBufferToAppend else {
                    logger.error("REC_PERF: captureOutput [Video Frame #\(self.videoFrameCount)] Failed: No valid pixel buffer (original or processed) to append.")
                    failedVideoFrames += 1
                    return
                }
                
                // Create a new sample buffer ONLY if we processed or if timing/format might change
                // For simplicity here, we always create a new one if processed, otherwise use original sampleBuffer.
                var finalSampleBuffer: CMSampleBuffer? = sampleBuffer // Default to original sample buffer
                
                if isProcessed {
                    // We have a processed pixel buffer, need to create a new sample buffer
                    var timing = CMSampleTimingInfo()
                    CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
                    
                    var info: CMFormatDescription?
                    let status = CMVideoFormatDescriptionCreateForImageBuffer(
                        allocator: kCFAllocatorDefault,
                        imageBuffer: finalPixelBuffer, // Use the (potentially processed) pixel buffer
                        formatDescriptionOut: &info
                    )
                    
                    if status == noErr, let formatDesc = info,
                       let newSampleBuffer = createSampleBuffer(
                           from: finalPixelBuffer, 
                           formatDescription: formatDesc, 
                           timing: &timing
                       ) {
                        finalSampleBuffer = newSampleBuffer
                    } else {
                        // Failed to create new sample buffer from processed pixel buffer
                        failedVideoFrames += 1
                        logger.warning("Failed to create new sample buffer from processed pixel buffer #\(self.videoFrameCount). Using original sample buffer.")
                        finalSampleBuffer = sampleBuffer // Fallback to original sample buffer
                        isProcessed = false // Mark as not processed since we fell back
                    }
                } else {
                    // No processing occurred, use the original sample buffer directly
                    finalSampleBuffer = sampleBuffer
                }
                
                // Append the appropriate sample buffer 
                if let bufferToAppend = finalSampleBuffer, // Keep check for valid buffer
                   let pixelBuffer = CMSampleBufferGetImageBuffer(bufferToAppend) { // Get pixel buffer from the final sample buffer
                    
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(bufferToAppend)

                    // --> Use the Pixel Buffer Adaptor <--
                    if let adaptor = assetWriterPixelBufferAdaptor {
                         adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                         successfulVideoFrames += 1
                    } else {
                         // This should ideally not happen if setup is correct
                         failedVideoFrames += 1
                         logger.error("Error: assetWriterPixelBufferAdaptor is nil for frame #\(self.videoFrameCount). Skipping append.")
                    }
                    // --> END Use the Pixel Buffer Adaptor <--
                } else {
                     // This case handles if bufferToAppend is nil OR getting pixelBuffer failed
                     failedVideoFrames += 1
                     logger.error("Error: Could not get final sample buffer or pixel buffer for frame #\(self.videoFrameCount). Skipping append.")
                }
            }
        }
        
        // Handle audio data
        if output == audioDataOutput,
           // ADD CHECK: Make sure we have a valid writer and the correct input
           assetWriter.status == .writing, 
           let audioInput = assetWriter.inputs.first(where: { $0.mediaType == .audio }),
           audioInput.isReadyForMoreMediaData {
            audioFrameCount += 1
            audioInput.append(sampleBuffer)
        }
    }
} 
