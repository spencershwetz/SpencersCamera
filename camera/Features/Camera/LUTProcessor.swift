import CoreImage
import CoreVideo
import UIKit

/// Processes camera frames with LUT filters
class LUTProcessor {
    private var lutFilter: CIFilter?
    private var isLogEnabled: Bool = false
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    
    /// Sets the LUT filter to use for processing
    /// - Parameter filter: The CIFilter to apply (typically CIColorCube)
    func setLUTFilter(_ filter: CIFilter?) {
        self.lutFilter = filter
    }
    
    /// Sets whether LOG mode is enabled
    /// - Parameter enabled: True if LOG mode is enabled
    func setLogEnabled(_ enabled: Bool) {
        self.isLogEnabled = enabled
    }
    
    /// Processes an image with the current LUT filter
    /// - Parameter image: The input CIImage
    /// - Returns: The processed CIImage, or nil if no processing was done
    func processImage(_ image: CIImage) -> CIImage? {
        guard let filter = lutFilter else { return nil }
        
        // Apply the LUT filter
        filter.setValue(image, forKey: kCIInputImageKey)
        var outputImage = filter.outputImage
        
        // Apply additional processing for LOG mode if enabled
        if isLogEnabled, let output = outputImage {
            outputImage = output.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.1,
                kCIInputBrightnessKey: 0.05
            ])
        }
        
        return outputImage
    }
    
    /// Creates a CGImage from a CIImage for display
    /// - Parameter image: The CIImage to convert
    /// - Returns: A CGImage, or nil if conversion failed
    func createCGImage(from image: CIImage) -> CGImage? {
        return ciContext.createCGImage(image, from: image.extent)
    }
} 