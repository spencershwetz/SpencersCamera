import AVFoundation
import Photos
import os.log
import UIKit
import CoreMedia
import CoreImage
import CoreVideo

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
    private var currentRecordingURL: URL?
    private var recordingStartTime: CMTime?
    private var isRecording = false
    private var selectedFrameRate: Double = 30.0
    private var selectedResolution: CameraViewModel.Resolution = .uhd
    private var selectedCodec: CameraViewModel.VideoCodec = .hevc
    private var ciContext = CIContext()
    private var currentVideoTransform: CGAffineTransform = .identity // Store the transform used for recording
    
    // Statistics for debugging
    private var videoFrameCount = 0
    private var audioFrameCount = 0
    private var successfulVideoFrames = 0
    private var failedVideoFrames = 0
    
    init(session: AVCaptureSession, delegate: RecordingServiceDelegate) {
        self.session = session
        self.delegate = delegate
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
    
    func startRecording(transform: CGAffineTransform) async {
        guard !isRecording else {
            logger.warning("Attempted to start recording while already recording.")
            return
        }

        logger.info("📱 Starting recording...")
        self.currentVideoTransform = transform
        logger.info("Using recording transform: a=\(transform.a), b=\(transform.b), c=\(transform.c), d=\(transform.d), tx=\(transform.tx), ty=\(transform.ty)")

        // Reset counters...
        videoFrameCount = 0
        audioFrameCount = 0
        successfulVideoFrames = 0
        failedVideoFrames = 0

        // --- Define local writer/input variables to handle potential nil state on error ---
        var localAssetWriter: AVAssetWriter? = nil
        var localAssetWriterInput: AVAssetWriterInput? = nil
        var localAudioInput: AVAssetWriterInput? = nil
        var localPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor? = nil
        var localTempURL: URL? = nil
        // -------------------------------------------------------------------------------

        do {
            // Create temporary URL...
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "recording_\(Date().timeIntervalSince1970).mov"
            localTempURL = tempDir.appendingPathComponent(fileName)
            guard let tempURL = localTempURL else { // Safely unwrap
                logger.error("Failed to create temporary URL.")
                throw CameraError.recordingFailed // Or a more specific error
            }
            currentRecordingURL = tempURL // Keep track for cleanup/saving

            logger.info("Creating asset writer at \(tempURL.path)")
            localAssetWriter = try AVAssetWriter(url: tempURL, fileType: .mov)
            guard let writer = localAssetWriter else { // Safely unwrap
                 logger.error("Failed to initialize AVAssetWriter.")
                 throw CameraError.recordingFailed
            }
            self.assetWriter = writer // Assign to instance variable

            // Get dimensions...
            guard let device = device else {
                logger.error("Camera device is nil in startRecording")
                throw CameraError.configurationFailed
            }
            let format = device.activeFormat
            guard let dimensions = format.dimensions else {
                logger.error("Could not get dimensions from active format: \(format)")
                throw CameraError.configurationFailed
            }
            let videoWidth = dimensions.width
            let videoHeight = dimensions.height

            // Configure video settings...
            var videoSettings: [String: Any] = [
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight
            ]
            // Codec settings... (keep existing logic)
            if selectedCodec == .proRes {
                videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
            } else {
                videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
                let compressionProperties: [String: Any] = [
                    AVVideoAverageBitRateKey: selectedCodec.bitrate,
                    AVVideoExpectedSourceFrameRateKey: NSNumber(value: selectedFrameRate),
                    AVVideoMaxKeyFrameIntervalKey: Int(selectedFrameRate),
                    AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: "HEVC_Main42210_AutoLevel",
                    AVVideoColorPrimariesKey: isAppleLogEnabled ? "ITU_R_2020" : "ITU_R_709_2",
                    AVVideoYCbCrMatrixKey: isAppleLogEnabled ? "ITU_R_2020" : "ITU_R_709_2",
                    "AllowOpenGOP": false,
                    "EncoderID": "com.apple.videotoolbox.videoencoder.hevc.422v2"
                ]
                videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties
            }

            // Create video input...
            localAssetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            guard let videoInput = localAssetWriterInput else {
                 logger.error("Failed to create AVAssetWriterInput for video.")
                 throw CameraError.recordingFailed
            }
            videoInput.expectsMediaDataInRealTime = true
            videoInput.transform = self.currentVideoTransform // Apply transform
            self.assetWriterInput = videoInput // Assign to instance variable
            logger.info("Created asset writer video input.") // Log success point

            // Configure audio settings...
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000, // Standard sample rate
                AVNumberOfChannelsKey: 2, // Stereo
                AVLinearPCMBitDepthKey: 16, // Standard bit depth
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            localAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            guard let audioInput = localAudioInput else {
                 logger.error("Failed to create AVAssetWriterInput for audio.")
                 throw CameraError.recordingFailed
            }
            audioInput.expectsMediaDataInRealTime = true
            logger.info("Created asset writer audio input.")

            // Create pixel buffer adaptor...
             guard let nonOptionalVideoInput = self.assetWriterInput else { // Ensure video input exists
                  logger.error("Video Asset Writer Input is nil before creating adaptor.")
                  throw CameraError.recordingFailed
             }
            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            localPixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: nonOptionalVideoInput,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
             guard localPixelBufferAdaptor != nil else {
                  logger.error("Failed to create Pixel Buffer Adaptor.")
                  throw CameraError.recordingFailed
             }
            self.assetWriterPixelBufferAdaptor = localPixelBufferAdaptor // Assign to instance variable
             logger.info("Created pixel buffer adaptor.")


            // Add inputs to writer...
            logger.info("Adding inputs to writer...")
            if writer.canAdd(videoInput) {
                writer.add(videoInput)
                logger.info("Added video input to asset writer")
            } else {
                logger.error("Failed to add video input. Writer status: \(writer.status.rawValue). Error: \(writer.error?.localizedDescription ?? "None")")
                throw CameraError.recordingFailed
            }
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                logger.info("Added audio input to asset writer")
            } else {
                // Maybe non-fatal, depends on requirements
                logger.error("Failed to add audio input. Writer status: \(writer.status.rawValue). Error: \(writer.error?.localizedDescription ?? "None")")
                // throw CameraError.recordingFailed // Optional: throw if audio is mandatory
            }
             logger.info("Finished adding inputs.") // Log success point


            // Start writing...
            logger.info("Attempting to start writing session...")
            recordingStartTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000000) // Use seconds for logging clarity
            guard let startTime = recordingStartTime else {
                 logger.error("Failed to get recording start time.")
                 throw CameraError.recordingFailed
            }

            let didStartWriting = writer.startWriting()
            guard didStartWriting else {
                logger.error("Asset writer startWriting() returned false. Status: \(writer.status.rawValue). Error: \(writer.error?.localizedDescription ?? "None")")
                throw CameraError.recordingFailed
            }
             logger.info("Asset writer startWriting() successful. Status: \(writer.status.rawValue)") // Should be .writing

            writer.startSession(atSourceTime: startTime)
            // Check status *after* starting session, as it can fail here too
            guard writer.status == .writing else {
                logger.error("Asset writer failed to enter writing state after startSession. Status: \(writer.status.rawValue). Error: \(writer.error?.localizedDescription ?? "None")")
                throw CameraError.recordingFailed
            }
             logger.info("Started asset writer session at time: \(startTime.seconds)")


            // If all setup succeeds:
            isRecording = true // Set internal state
            delegate?.didStartRecording() // Notify delegate

            logger.info("✅ Successfully started recording to: \(tempURL.path)")
            logger.info("Recording settings - Resolution: \(videoWidth)x\(videoHeight), Codec: \(self.selectedCodec.rawValue), Frame Rate: \(self.selectedFrameRate)")

        } catch {
            logger.error("❌ Failed during startRecording setup: \(error.localizedDescription)")
            // Enhanced Cleanup: Ensure all potentially created objects are nilled out
            self.assetWriter = nil
            self.assetWriterInput = nil
            self.assetWriterPixelBufferAdaptor = nil
            self.recordingStartTime = nil
            // Don't nil currentRecordingURL yet, might be needed if partial file exists? Or remove partial file?
            // if let url = currentRecordingURL { try? FileManager.default.removeItem(at: url) }
            self.currentRecordingURL = nil // Decide on cleanup strategy

            isRecording = false // Ensure state is false on failure
            // Pass the specific error if possible, otherwise generic .recordingFailed
             if let cameraError = error as? CameraError {
                 delegate?.didEncounterError(cameraError)
             } else {
                 delegate?.didEncounterError(.recordingFailed)
             }
        }
    }

    func stopRecording() async {
        guard isRecording else { return }

        logger.info("Finalizing video with \(self.videoFrameCount) frames (\(self.successfulVideoFrames) successful, \(self.failedVideoFrames) failed)")

        await MainActor.run {
            delegate?.didUpdateProcessingState(true)
        }

        // Mark all inputs as finished...
        assetWriterInput?.markAsFinished()
        // Assuming audioInput is correctly retrieved or stored if needed for finishing
        assetWriter?.inputs.first(where: { $0.mediaType == .audio })?.markAsFinished() // Finish audio input too
        logger.info("Marked asset writer inputs as finished")

        // Wait for asset writer...
        if let assetWriter = assetWriter {
            logger.info("Waiting for asset writer to finish writing...")
            await assetWriter.finishWriting()
            logger.info("Asset writer finished with status: \(assetWriter.status.rawValue)")
            if let error = assetWriter.error {
                logger.error("Asset writer error: \(error.localizedDescription)")
            }
        }

        // Reset recording state...
        isRecording = false
        delegate?.didStopRecording()
        recordingStartTime = nil

        // Save to photo library...
        if let outputURL = currentRecordingURL {
            logger.info("Saving video to photo library: \(outputURL.path)")
            let thumbnail = await generateThumbnail(from: outputURL)
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

    // Public method for CameraViewModel to call with sample buffers
    func processFrame(output: AVCaptureOutput, sampleBuffer: CMSampleBuffer, connection: AVCaptureConnection) {
        guard isRecording,
              let assetWriter = assetWriter else {
            return
        }

        // Check writer status before attempting append
        guard assetWriter.status == .writing else {
            // Log writer status if it's not writing (e.g., failed, completed, cancelled)
             if videoFrameCount % 30 == 0 { // Log periodically
                 logger.error("Asset writer is not in writing state (\(assetWriter.status.rawValue)). Skipping frame #\(self.videoFrameCount). Error: \(assetWriter.error?.localizedDescription ?? "None")")
             }
            // Consider stopping recording or signaling an error if status is failed
            return
        }

        // Handle video data
        // Check if the output matches the expected video output type.
        if let assetWriterInput = assetWriterInput, // Check if video input exists
           assetWriterInput.isReadyForMoreMediaData,
           output is AVCaptureVideoDataOutput { // Check if it's the video output

            videoFrameCount += 1
            let shouldLog = videoFrameCount % 30 == 0

            var appendSuccess = false
            var bufferToAppend: CMSampleBuffer? = nil

            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                if isBakeInLUTEnabled, let lutManager = lutManager, lutManager.currentLUTFilter != nil {
                    // --- LUT Processing Logic ---
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    if let processedImage = applyLUT(to: ciImage),
                       let processedPixelBuffer = createPixelBuffer(from: processedImage, with: pixelBuffer) {

                        var timing = CMSampleTimingInfo()
                        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)

                        var info: CMFormatDescription?
                        let status = CMVideoFormatDescriptionCreateForImageBuffer(
                            allocator: kCFAllocatorDefault,
                            imageBuffer: processedPixelBuffer,
                            formatDescriptionOut: &info
                        )

                        if status == noErr, let info = info {
                            bufferToAppend = createSampleBuffer(
                                from: processedPixelBuffer,
                                formatDescription: info,
                                timing: &timing
                            )
                            if bufferToAppend == nil {
                                logger.warning("Failed to create sample buffer for processed frame #\(self.videoFrameCount)")
                            }
                        } else {
                             logger.warning("Failed to create format description for processed frame #\(self.videoFrameCount)")
                        }
                    } else {
                         logger.warning("Failed to process or create pixel buffer for LUT frame #\(self.videoFrameCount)")
                    }
                     // --- End LUT Processing ---
                } else {
                    // No LUT processing needed - use original sample buffer directly
                    bufferToAppend = sampleBuffer
                }

                // Attempt to append the buffer (either original or processed)
                if let finalBuffer = bufferToAppend {
                    // Make sure assetWriterInput is ready one last time before appending
                    if assetWriterInput.isReadyForMoreMediaData {
                        appendSuccess = assetWriterInput.append(finalBuffer)
                    } else {
                        appendSuccess = false // Not ready, so append fails
                        if shouldLog {
                            logger.warning("Video input not ready for frame #\(self.videoFrameCount)")
                        }
                    }
                }
            } else {
                 logger.warning("Could not get pixel buffer from sample buffer frame #\(self.videoFrameCount)")
            }

            // Update counters and log status
            if appendSuccess {
                successfulVideoFrames += 1
                if shouldLog {
                    logger.debug("Appended video frame #\(self.videoFrameCount) (Success: \(self.successfulVideoFrames))")
                }
            } else {
                failedVideoFrames += 1
                // Check writer status *after* a failed append
                if assetWriter.status != .writing {
                     logger.error("Asset writer status changed to \(assetWriter.status.rawValue) after failed append of frame #\(self.videoFrameCount). Error: \(assetWriter.error?.localizedDescription ?? "None")")
                     // Optionally trigger stop/error handling here
                } else if shouldLog || failedVideoFrames == 1 { // Log first failure and periodically after
                    logger.warning("Failed to append video frame #\(self.videoFrameCount) (Failed: \(self.failedVideoFrames)). Writer status: \(assetWriter.status.rawValue)")
                }
            }
        } // End Video Handling

        // Handle audio data
        // Check if the output matches the expected audio output type
        if let audioInput = assetWriter.inputs.first(where: { $0.mediaType == .audio }),
           audioInput.isReadyForMoreMediaData,
           output is AVCaptureAudioDataOutput { // Check if it's the audio output

            // Check writer status before appending audio too
             guard assetWriter.status == .writing else { return }

            let appendSuccess = audioInput.append(sampleBuffer)
             if appendSuccess {
                audioFrameCount += 1
                if audioFrameCount % 100 == 0 { // Log periodically
                    logger.debug("Appended audio frame #\(self.audioFrameCount)")
                }
             } else {
                 if assetWriter.status != .writing {
                     logger.error("Asset writer status changed to \(assetWriter.status.rawValue) after failed audio append. Error: \(assetWriter.error?.localizedDescription ?? "None")")
                 } else if audioFrameCount % 100 == 0 { // Log periodically on failure too
                     logger.warning("Failed to append audio frame #\(self.audioFrameCount). Writer status: \(assetWriter.status.rawValue)")
                 }
             }
        } // End Audio Handling
    } // End processFrame method

} // End RecordingService class
