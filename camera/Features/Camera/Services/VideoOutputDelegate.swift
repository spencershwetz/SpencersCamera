import AVFoundation
import CoreImage

class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    let lutManager: LUTManager
    let viewModel: CameraViewModel
    let context: CIContext
    
    // Counter to limit debug logging
    private static var frameCounter = 0
    
    init(lutManager: LUTManager, viewModel: CameraViewModel, context: CIContext) {
        self.lutManager = lutManager
        self.viewModel = viewModel
        self.context = context
        super.init()
        
        print("VideoOutputDelegate initialized")
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        VideoOutputDelegate.frameCounter += 1
        
        // Only print debug logging every 60 frames to avoid console spam
        let isLoggingFrame = VideoOutputDelegate.frameCounter % 60 == 0
        // After 120 frames, only log important events
        let isEstablishedStream = VideoOutputDelegate.frameCounter > 120
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            if isLoggingFrame && !isEstablishedStream {
                print("Could not get pixel buffer from sample buffer")
            }
            return
        }
        
        // Create CIImage from the pixel buffer
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // If Apple Log is enabled, handle LOG processing
        if viewModel.isAppleLogEnabled {
            if isLoggingFrame && !isEstablishedStream {
                print("Processing LOG image")
            }
        }
        
        // Apply LUT if available
        if lutManager.currentLUTFilter != nil {
            if isLoggingFrame && !isEstablishedStream {
                print("Attempting to apply LUT filter")
            }
            
            if let processedImage = lutManager.applyLUT(to: ciImage) {
                ciImage = processedImage
                
                if isLoggingFrame && !isEstablishedStream {
                    print("✅ LUT applied successfully")
                }
            } else if isLoggingFrame {
                print("❌ LUT application failed")
            }
        }
        
        // Render the processed image back to the pixel buffer
        context.render(ciImage, to: pixelBuffer)
        
        // Process the frame in the viewModel - just check if processing succeeded
        if viewModel.processVideoFrame(sampleBuffer) != nil {
            if isLoggingFrame && !isEstablishedStream {
                print("Frame processed successfully")
            }
        }
        
        // Shutter angle debug removed to reduce console spam
    }
} 