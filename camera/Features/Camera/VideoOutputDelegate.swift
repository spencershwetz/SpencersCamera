import AVFoundation
import CoreImage

class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let lutManager: LUTManager
    let viewModel: CameraViewModel
    let context = CIContext()
    
    init(lutManager: LUTManager, viewModel: CameraViewModel) {
        self.lutManager = lutManager
        self.viewModel = viewModel
        super.init()
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        
        // Process the image through our pipeline
        print("🎥 Processing image pipeline:")
        print("  - Input image: \(ciImage)")
        
        var processedImage = ciImage
        
        if viewModel.isAppleLogEnabled {
            print("  - Apple Log enabled, converting...")
            // Apple Log processing is handled by the camera format
        }
        
        if lutManager.currentLUTFilter != nil {
            print("  - Applying LUT filter...")
            if let lutImage = lutManager.applyLUT(to: processedImage) {
                processedImage = lutImage
                print("  ✅ LUT applied successfully")
            } else {
                print("  ❌ Failed to apply LUT")
            }
        } else {
            print("  ℹ️ No LUT filter active")
        }
        
        print("  - Final output image: \(processedImage)")
        
        // Render the processed image back to the pixel buffer
        if let pixelBuffer = imageBuffer as CVPixelBuffer? {
            context.render(processedImage, to: pixelBuffer)
        }
    }
} 