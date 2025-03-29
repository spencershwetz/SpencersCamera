import AVFoundation
import CoreImage
import CoreMedia
import UIKit

// MARK: - Image Processing Extensions
extension CameraViewModel {
    
    func processVideoFrame(_ sampleBuffer: CMSampleBuffer) -> CIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("DEBUG: No pixel buffer in sample buffer")
            return nil
        }
        
        // Create CIImage from the pixel buffer
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Apply LUT filter if available
        if let lutFilter = lutManager.currentLUTFilter {
            lutFilter.setValue(ciImage, forKey: kCIInputImageKey)
            if let outputImage = lutFilter.outputImage {
                return outputImage
            } else {
                // If LUT application fails, return the original image
                print("DEBUG: LUT filter failed to produce output image, using original")
                return ciImage
            }
        }
        
        // No LUT filter applied, return original image
        return ciImage
    }
    
    func applyLUT(to image: CIImage, using lutFilter: CIFilter) -> CIImage? {
        lutFilter.setValue(image, forKey: kCIInputImageKey)
        return lutFilter.outputImage
    }
    
    func createPixelBuffer(from ciImage: CIImage, with template: CVPixelBuffer) -> CVPixelBuffer? {
        var newPixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,
                           CVPixelBufferGetWidth(template),
                           CVPixelBufferGetHeight(template),
                           CVPixelBufferGetPixelFormatType(template),
                           [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                           &newPixelBuffer)
        
        guard let outputBuffer = newPixelBuffer else { 
            print("⚠️ Failed to create pixel buffer from CI image")
            return nil 
        }
        
        ciContext.render(ciImage, to: outputBuffer)
        return outputBuffer
    }
    
    func createSampleBuffer(
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
            print("⚠️ Failed to create sample buffer: \(status)")
            return nil
        }
        
        return sampleBuffer
    }
} 