import AVFoundation
import CoreImage
import os

class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    let lutManager: LUTManager
    let viewModel: CameraViewModel
    
    // Counter to limit debug logging
    static var frameCounter = 0
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "VideoOutputDelegate")
    
    init(lutManager: LUTManager, viewModel: CameraViewModel/*, context: CIContext*/) {
        self.lutManager = lutManager
        self.viewModel = viewModel
        // self.context = context
        super.init()
        
        print("VideoOutputDelegate initialized without CIContext") // Update log message
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        VideoOutputDelegate.frameCounter += 1
        
        // Determine if stream is established first
        let isEstablishedStream = VideoOutputDelegate.frameCounter > 120
        // Log less frequently after initial stream
        let logFrequency = isEstablishedStream ? 300 : 60 // Log every 5s vs every 1s initially
        let isLoggingFrame = VideoOutputDelegate.frameCounter % logFrequency == 0

        if isLoggingFrame {
            logger.debug("--> captureOutput frame \(VideoOutputDelegate.frameCounter)")
        }
        
        // Check if pixel buffer exists, don't need the variable itself
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.error("Failed to get pixel buffer from sample buffer")
            return
        }
        
        // Process the frame in the viewModel
        // IMPORTANT: Log what processVideoFrame does with the buffer, especially regarding orientation
        if isLoggingFrame {
            logger.debug("    [captureOutput] Calling viewModel.processVideoFrame...")
        }

        // --- START COMMENT OUT BUFFER LOG ---
        // // Log the pixel buffer format less frequently
        // if isLoggingFrame {
        //     let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        //     let mediaTypeUInt = CMFormatDescriptionGetMediaType(CMSampleBufferGetFormatDescription(sampleBuffer)!)
        //     let mediaTypeStr = FourCCString(mediaTypeUInt) // Convert media type code
        //     let formatStr = FourCCString(pixelFormat) // Convert pixel format code
        //     logger.debug("    [captureOutput] Processing pixel buffer: Format=\(formatStr) (\(pixelFormat)), MediaType=\(mediaTypeStr) (\(mediaTypeUInt))")
        // }
        // --- END COMMENT OUT BUFFER LOG ---

        if viewModel.processVideoFrame(sampleBuffer) != nil {
            if isLoggingFrame {
                logger.debug("    [captureOutput] viewModel.processVideoFrame succeeded.")
            }
        } else if isLoggingFrame {
             logger.warning("    [captureOutput] viewModel.processVideoFrame returned nil.")
        }
        
        if isLoggingFrame {
            logger.debug("<-- captureOutput finished frame \(VideoOutputDelegate.frameCounter)")
        }
    }
} 