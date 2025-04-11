import AVFoundation
import CoreImage
import os

class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    let lutManager: LUTManager
    let viewModel: CameraViewModel
    let context: CIContext
    
    // Counter to limit debug logging
    static var frameCounter = 0
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "VideoOutputDelegate")
    
    init(lutManager: LUTManager, viewModel: CameraViewModel, context: CIContext) {
        self.lutManager = lutManager
        self.viewModel = viewModel
        self.context = context
        super.init()
        
        print("VideoOutputDelegate initialized")
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
        
        // Revert back to guard let to make pixelBuffer available
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.error("Failed to get pixel buffer from sample buffer")
            return
        }
        
        // Create CIImage from the pixel buffer
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        var didApplyLUT = false

        // If Apple Log is enabled, handle LOG processing
        if viewModel.isAppleLogEnabled {
            if isLoggingFrame {
                logger.debug("    [captureOutput] Apple Log ENABLED")
            }
            // Potentially add more logs specific to LOG processing if needed
        }
        
        // Apply LUT if available
        if lutManager.currentLUTFilter != nil {
            if isLoggingFrame {
                logger.debug("    [captureOutput] Attempting to apply LUT filter...")
            }
            if let processedImage = lutManager.applyLUT(to: ciImage) {
                ciImage = processedImage
                didApplyLUT = true
                if isLoggingFrame {
                    logger.debug("    [captureOutput] ✅ LUT applied successfully by LUTManager")
                }
            } else if isLoggingFrame {
                logger.error("    [captureOutput] ❌ LUT application FAILED (returned nil from LUTManager)")
            }
        } else if isLoggingFrame {
             logger.debug("    [captureOutput] No LUT filter active.")
        }
        
        // Render the processed image back to the pixel buffer
        // Note: This modifies the original pixelBuffer that might be used elsewhere!
        // Consider if rendering to a *new* buffer is safer depending on viewModel.processVideoFrame usage.
        if isLoggingFrame { 
             logger.debug("    [captureOutput] Rendering CIImage (LUT applied: \(didApplyLUT)) back to CVPixelBuffer...")
        }
        context.render(ciImage, to: pixelBuffer)
        if isLoggingFrame { 
             logger.debug("    [captureOutput] Rendering finished.")
        }

        // Process the frame in the viewModel
        // IMPORTANT: Log what processVideoFrame does with the buffer, especially regarding orientation
        if isLoggingFrame {
             logger.debug("    [captureOutput] Calling viewModel.processVideoFrame...")
        }
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