import AVFoundation
import Photos
import CoreVideo
import CoreMedia
import UIKit
import os.log
import VideoToolbox

// MARK: - Recording Extensions
extension CameraViewModel {
    
    @MainActor
    func startRecording() async {
        guard !isRecording else { return }
        
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
            
            print("🎬 START RECORDING: Creating asset writer at \(tempURL.path)")
            
            // Create asset writer
            assetWriter = try AVAssetWriter(url: tempURL, fileType: .mov)
            
            // Get dimensions from current format
            guard let device = device,
                  let dimensions = device.activeFormat.dimensions else {
                throw CameraError.configurationFailed
            }
            
            // Configure video settings based on current configuration
            var videoSettings: [String: Any] = [
                AVVideoWidthKey: dimensions.width,
                AVVideoHeightKey: dimensions.height
            ]
            
            if selectedCodec == .proRes {
                videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
                // ProRes doesn't use compression properties
            } else {
                videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
                
                // Create a single dictionary for all compression properties
                let compressionProperties: [String: Any] = [
                    AVVideoAverageBitRateKey: selectedCodec.bitrate,
                    AVVideoExpectedSourceFrameRateKey: NSNumber(value: selectedFrameRate),
                    AVVideoMaxKeyFrameIntervalKey: Int(selectedFrameRate), // One keyframe per second
                    AVVideoMaxKeyFrameIntervalDurationKey: 1.0, // Force keyframe every second
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: VTConstants.hevcMain422_10Profile,
                    AVVideoColorPrimariesKey: isAppleLogEnabled ? VTConstants.primariesBT2020 : VTConstants.primariesITUR709,
                    AVVideoYCbCrMatrixKey: isAppleLogEnabled ? VTConstants.yCbCrMatrix2020 : VTConstants.yCbCrMatrixITUR709,
                    "AllowOpenGOP": false,
                    "EncoderID": "com.apple.videotoolbox.videoencoder.hevc.422v2"
                ]
                
                videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties
            }
            
            // Create video input with better buffer handling
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true
            
            // Apply transform based on current device orientation
            let deviceOrientation = UIDevice.current.orientation
            assetWriterInput?.transform = transformForDeviceOrientation(deviceOrientation)
            
            print("📝 Created asset writer input with settings: \(videoSettings)")
            
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
            
            print("📐 Created pixel buffer adaptor with format: BGRA (32-bit)")
            
            // Add inputs to writer
            if assetWriter!.canAdd(assetWriterInput!) {
                assetWriter!.add(assetWriterInput!)
                print("✅ Added video input to asset writer")
            } else {
                print("❌ FAILED to add video input to asset writer")
            }
            
            if assetWriter!.canAdd(audioInput) {
                assetWriter!.add(audioInput)
                print("✅ Added audio input to asset writer")
            } else {
                print("❌ FAILED to add audio input to asset writer")
            }
            
            // Configure video data output if not already configured
            if videoDataOutput == nil {
                videoDataOutput = AVCaptureVideoDataOutput()
                videoDataOutput?.setSampleBufferDelegate(self, queue: processingQueue)
                if session.canAddOutput(videoDataOutput!) {
                    session.addOutput(videoDataOutput!)
                    print("✅ Added video data output to session")
                } else {
                    print("❌ FAILED to add video data output to session")
                }
            } else {
                print("✅ Using existing video data output")
            }
            
            // Configure audio data output if not already configured
            if audioDataOutput == nil {
                audioDataOutput = AVCaptureAudioDataOutput()
                audioDataOutput?.setSampleBufferDelegate(self, queue: processingQueue)
                if session.canAddOutput(audioDataOutput!) {
                    session.addOutput(audioDataOutput!)
                    print("✅ Added audio data output to session")
                } else {
                    print("❌ FAILED to add audio data output to session")
                }
            } else {
                print("✅ Using existing audio data output")
            }
            
            // Start writing
            recordingStartTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000000)
            assetWriter!.startWriting()
            assetWriter!.startSession(atSourceTime: recordingStartTime!)
            
            print("▶️ Started asset writer session at time: \(recordingStartTime!.seconds)")
            
            isRecording = true
            print("✅ Started recording to: \(tempURL.path)")
            print("📊 Recording settings:")
            print("- Resolution: \(dimensions.width)x\(dimensions.height)")
            print("- Codec: \(selectedCodec == .proRes ? "ProRes 422 HQ" : "HEVC")")
            print("- Color Space: \(isAppleLogEnabled ? "Apple Log (BT.2020)" : "Rec.709")")
            print("- Chroma subsampling: 4:2:2")
            print("- Frame Rate: \(selectedFrameRate) fps")
            print("- Start Time: \(recordingStartTime!.seconds)")
            
        } catch {
            self.error = .recordingFailed
            print("❌ Failed to start recording: \(error)")
        }
    }
    
    @MainActor
    func stopRecording() async {
        guard isRecording else { return }
        
        print("⏹️ STOP RECORDING: Finalizing video with \(videoFrameCount) frames (\(successfulVideoFrames) successful, \(failedVideoFrames) failed)")
        
        isProcessingRecording = true
        
        // Mark all inputs as finished
        assetWriterInput?.markAsFinished()
        print("✅ Marked asset writer inputs as finished")
        
        // Wait for asset writer to finish
        if let assetWriter = assetWriter {
            print("⏳ Waiting for asset writer to finish writing...")
            await assetWriter.finishWriting()
            print("✅ Asset writer finished with status: \(assetWriter.status.rawValue)")
            
            if let error = assetWriter.error {
                print("❌ Asset writer error: \(error)")
            }
        }
        
        // Clean up recording resources
        if let videoDataOutput = videoDataOutput {
            session.removeOutput(videoDataOutput)
            self.videoDataOutput = nil
            print("🧹 Removed video data output from session")
        }
        
        if let audioDataOutput = audioDataOutput {
            session.removeOutput(audioDataOutput)
            self.audioDataOutput = nil
            print("🧹 Removed audio data output from session")
        }
        
        // Reset recording state
        isRecording = false
        recordingStartTime = nil
        
        // Save to photo library if we have a valid recording
        if let outputURL = currentRecordingURL {
            print("💾 Saving video to photo library: \(outputURL.path)")
            
            // Check file size
            let fileManager = FileManager.default
            if let attributes = try? fileManager.attributesOfItem(atPath: outputURL.path),
               let fileSize = attributes[.size] as? Int {
                print("📊 Video file size: \(fileSize / 1024 / 1024) MB")
            }
            
            // Check duration using AVAsset
            let asset = AVURLAsset(url: outputURL)
            let durationTime: CMTime
            
            if #available(iOS 16.0, *) {
                do {
                    durationTime = try await asset.load(.duration)
                } catch {
                    durationTime = CMTime.zero
                    print("Error loading duration: \(error)")
                }
            } else {
                durationTime = asset.duration
            }
            
            print("⏱️ Video duration: \(CMTimeGetSeconds(durationTime)) seconds")
            
            await saveToPhotoLibrary(outputURL)
        }
        
        // Clean up
        assetWriter = nil
        assetWriterInput = nil
        assetWriterPixelBufferAdaptor = nil
        currentRecordingURL = nil
        isProcessingRecording = false
        
        print("🏁 Recording session completed")
    }
    
    private func saveToPhotoLibrary(_ outputURL: URL) async {
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized else {
                await MainActor.run {
                    self.error = .savingFailed
                    print("Photo library access denied")
                }
                return
            }
            
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .video, fileURL: outputURL, options: options)
            }
            
            await MainActor.run {
                print("Video saved to photo library")
                self.recordingFinished = true
            }
        } catch {
            await MainActor.run {
                print("Error saving video: \(error)")
                self.error = .savingFailed
            }
        }
    }
    
    private func generateThumbnail(from videoURL: URL) {
        let asset = AVURLAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        // Get thumbnail from first frame
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        
        // Use async thumbnail generation
        imageGenerator.generateCGImageAsynchronously(for: time) { [weak self] cgImage, actualTime, error in
            if let error = error {
                print("Error generating thumbnail: \(error)")
                return
            }
            
            if let cgImage = cgImage {
                DispatchQueue.main.async {
                    self?.lastRecordedVideoThumbnail = UIImage(cgImage: cgImage)
                }
            }
        }
    }
    
    private func transformForDeviceOrientation(_ orientation: UIDeviceOrientation) -> CGAffineTransform {
        switch orientation {
        case .portrait:
            return CGAffineTransform(rotationAngle: .pi/2)
        case .landscapeLeft: // USB-C port on right
            return CGAffineTransform(rotationAngle: 0)
        case .landscapeRight: // USB-C port on left
            return CGAffineTransform(rotationAngle: .pi)
        case .portraitUpsideDown:
            return CGAffineTransform(rotationAngle: -.pi/2)
        default:
            return CGAffineTransform(rotationAngle: .pi/2) // Default to portrait
        }
    }
    
    private func setupHEVCEncoder() throws {
        print("\n=== Setting up HEVC Hardware Encoder ===")
        
        // Clean up any existing session
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        
        // Get dimensions from the active format
        guard let device = device,
              let dimensions = device.activeFormat.dimensions else {
            throw CameraError.configurationFailed
        }
        
        // Create compression session
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(dimensions.width),
            height: Int32(dimensions.height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { outputCallbackRefCon, sourceFrameRefCon, status, flags, sampleBuffer in
                guard sampleBuffer != nil else { return }
                DispatchQueue.main.async {
                    print("✅ Encoded HEVC frame received")
                }
            },
            refcon: nil,
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            print("❌ Failed to create compression session: \(status)")
            throw CameraError.configurationFailed
        }
        
        // Configure encoder properties
        let properties: [String: Any] = [
            kVTCompressionPropertyKey_RealTime.string: true,
            kVTCompressionPropertyKey_ProfileLevel.string: VTConstants.hevcMain422_10Profile,
            kVTCompressionPropertyKey_MaxKeyFrameInterval.string: Int32(selectedFrameRate),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration.string: 1,
            kVTCompressionPropertyKey_AllowFrameReordering.string: false,
            VTConstants.priority.string: VTConstants.priorityRealtimePreview,
            kVTCompressionPropertyKey_AverageBitRate.string: selectedCodec.bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate.string: selectedFrameRate,
            kVTCompressionPropertyKey_ColorPrimaries.string: isAppleLogEnabled ? VTConstants.primariesBT2020 : VTConstants.primariesITUR709,
            kVTCompressionPropertyKey_YCbCrMatrix.string: isAppleLogEnabled ? VTConstants.yCbCrMatrix2020 : VTConstants.yCbCrMatrixITUR709,
            kVTCompressionPropertyKey_EncoderID.string: "com.apple.videotoolbox.videoencoder.hevc.422v2"
        ]
        
        // Apply properties
        for (key, value) in properties {
            let propStatus = VTSessionSetProperty(session, key: key as CFString, value: value as CFTypeRef)
            if propStatus != noErr {
                print("⚠️ Failed to set property \(key): \(propStatus)")
            }
        }
        
        // Prepare to encode frames
        VTCompressionSessionPrepareToEncodeFrames(session)
        
        // Store the session
        compressionSession = session
        print("✅ HEVC Hardware encoder setup complete")
        print("=== End HEVC Encoder Setup ===\n")
    }
    
    private func encodeFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let compressionSession = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CMSampleBufferGetFormatDescription(sampleBuffer) != nil else {
            return
        }
        
        // Get frame timing info
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
        
        // Create properties for encoding
        var properties: [String: Any] = [:]
        if CMSampleBufferGetNumSamples(sampleBuffer) > 0 {
            properties[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true
        }
        
        // Encode the frame
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: timing.presentationTimeStamp,
            duration: timing.duration,
            frameProperties: properties as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        
        if status != noErr {
            print("⚠️ Failed to encode frame: \(status)")
        }
    }
    
    func updateVideoConfiguration() {
        print("\n=== Updating Video Configuration ===")
        print("🎬 Selected Codec: \(selectedCodec.rawValue)")
        print("🎨 Apple Log Enabled: \(isAppleLogEnabled)")
        
        // Configure video settings based on codec
        if selectedCodec == .proRes {
            print("✅ Configured for ProRes recording")
            print("📊 Using codec: ProRes 422 HQ")
        } else {
            print("✅ Configured for HEVC recording")
            print("📊 Configured with:")
            print("- Codec: HEVC")
            print("- Bitrate: \(selectedCodec.bitrate / 1_000_000) Mbps")
            print("- Frame Rate: \(selectedFrameRate) fps")
            print("- Color Space: \(isAppleLogEnabled ? "Apple Log (BT.2020)" : "Rec.709")")
            print("- Matrix: \(isAppleLogEnabled ? "BT.2020 non-constant" : "Rec.709")")
            print("- Transfer: Apple Log")
            print("- Chroma subsampling: 4:2:2")
            print("- Profile Level: \(isAppleLogEnabled ? "HEVC_Main42210_AutoLevel" : "HEVC_Main_AutoLevel")")
        }
        
        print("=== End Video Configuration ===\n")
    }
} 