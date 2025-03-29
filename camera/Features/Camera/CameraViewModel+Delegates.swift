import AVFoundation
import CoreMedia
import CoreImage

// MARK: - Delegate Implementations
extension CameraViewModel {
    // Track frame counts for logging
    
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
            
            // Get the original presentation time
            _ = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
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
            // Update frame count locally
            let newAudioFrameCount = audioFrameCount + 1
            
            // Update @Published property on main thread
            DispatchQueue.main.async {
                self.audioFrameCount = newAudioFrameCount
            }
            
            audioInput.append(sampleBuffer)
            if newAudioFrameCount % 100 == 0 {
                print("🎵 Processed audio frame #\(newAudioFrameCount)")
            }
        }
    }
} 