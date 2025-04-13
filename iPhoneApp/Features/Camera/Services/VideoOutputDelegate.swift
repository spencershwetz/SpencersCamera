import AVFoundation
import CoreImage
import os

class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    let lutManager: LUTManager
    let viewModel: CameraViewModel
    let context: CIContext
    
    // Counter to limit debug logging
    private static var frameCounter: Int = 0
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "VideoOutputDelegate")
    private let logFrequency = 1 // Log every frame for bake-in investigation
    
    init(lutManager: LUTManager, viewModel: CameraViewModel, context: CIContext) {
        self.lutManager = lutManager
        self.viewModel = viewModel
        self.context = context
        super.init()
        
        print("VideoOutputDelegate initialized")
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        VideoOutputDelegate.frameCounter += 1
        let isLoggingFrame = VideoOutputDelegate.frameCounter % logFrequency == 0
        
        // Ensure we have a valid pixel buffer
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            logger.warning("Failed to get pixel buffer from sample buffer.")
            return
        }
        
        // --- Remove LUT Application Logic --- 
        // No LUT processing needed in the delegate. 
        // RecordingService handles bake-in based on its state.
        // MetalPreview handles preview LUT via shaders.
        
        // --- Frame Processing ---
        // Always pass the raw sample buffer to the view model.
        if isLoggingFrame { logger.debug("VIDEOUTPUT: Calling viewModel.processVideoFrame...") }
        // let processedBuffer = viewModel.processVideoFrame(sampleBuffer) // REMOVED call to non-existent method
        
        // --- Remove Metal Preview Update --- 
        // This is handled elsewhere, likely triggered by the ViewModel.
        
        if isLoggingFrame {
             logger.debug("<-- captureOutput frame \\(VideoOutputDelegate.frameCounter)")
        }
    }
} 