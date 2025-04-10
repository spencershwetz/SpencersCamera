import CoreImage
import CoreVideo
import UIKit
import OSLog // Add OSLog for logging

/// Processes camera frames with LUT filters
class LUTProcessor {
    private var lutFilter: CIFilter?
    private var isLogEnabled: Bool = false // Note: isLogEnabled is set but not currently used in processImage
    // Use the shared CIContext for efficiency
    private let ciContext = CIContext.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "LUTProcessor")
    
    // Add public getter for the current filter
    var currentLUTFilter: CIFilter? {
        return lutFilter
    }
    
    /// Sets the LUT filter to use for processing
    /// - Parameter filter: The CIFilter to apply (typically CIColorCube)
    func setLUTFilter(_ filter: CIFilter?) {
        self.lutFilter = filter
        logger.debug("LUT filter set: \(filter != nil ? "Yes" : "No")")
    }
    
    /// Sets whether LOG mode is enabled (Currently unused in processing logic)
    /// - Parameter enabled: True if LOG mode is enabled
    func setLogEnabled(_ enabled: Bool) {
        // This state is set but no longer used after removing CIColorControls.
        // Keeping the setter in case it's needed for future logic.
        self.isLogEnabled = enabled
        logger.debug("Log mode set to: \(enabled)")
    }
    
    /// Processes an image with the current LUT filter
    /// - Parameter image: The input CIImage
    /// - Returns: The processed CIImage, or the original if no filter is set.
    func processImage(_ image: CIImage) -> CIImage? {
        guard let filter = lutFilter else {
            logger.trace("processImage: No LUT filter set, returning original image.")
            return image // Return original if no filter
        }
        
        // Apply the LUT filter
        filter.setValue(image, forKey: kCIInputImageKey)
        let outputImage = filter.outputImage
        logger.trace("processImage: Applied LUT filter.")
        return outputImage
    }
    
    /// Processes a pixel buffer with the current LUT filter.
    /// - Parameter pixelBuffer: The input CVPixelBuffer.
    /// - Returns: A new CVPixelBuffer containing the processed image, or nil on failure or if no LUT is applied.
    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        logger.trace("processPixelBuffer: Starting processing.")
        let originalImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        guard let processedCIImage = processImage(originalImage) else {
            // processImage only returns nil if the filter itself fails,
            // but if it returns the original image (because no filter was set),
            // we should handle that here to avoid unnecessary rendering.
            logger.trace("processPixelBuffer: processImage returned nil or original, no processing needed.")
            return nil // Indicate no processing was performed (or filter failed)
        }
        
        // If the processed image is the same as the original (no filter applied), return nil
        if processedCIImage === originalImage {
             logger.trace("processPixelBuffer: Processed image is same as original (no filter applied).")
             return nil
        }
        
        // Create a new pixel buffer to render into
        var newPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         CVPixelBufferGetWidth(pixelBuffer),
                                         CVPixelBufferGetHeight(pixelBuffer),
                                         CVPixelBufferGetPixelFormatType(pixelBuffer),
                                         // Propagate attachments? Check if needed. Using basic attributes for now.
                                         [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                                         &newPixelBuffer)
        
        guard status == kCVReturnSuccess, let outputBuffer = newPixelBuffer else {
            logger.error("Failed to create output pixel buffer. Status: \(status)")
            return nil
        }
        
        // Render the processed CIImage into the new CVPixelBuffer
        ciContext.render(processedCIImage, to: outputBuffer)
        logger.trace("processPixelBuffer: Successfully rendered processed image to new buffer.")
        
        return outputBuffer
    }
    
    /// Creates a CGImage from a CIImage for display
    /// - Parameter image: The CIImage to convert
    /// - Returns: A CGImage, or nil if conversion failed
    func createCGImage(from image: CIImage) -> CGImage? {
        return ciContext.createCGImage(image, from: image.extent)
    }
} 