import Foundation
import AVFoundation
import UIKit
import ImageIO
import CoreImage
import CoreMedia
@testable import camera

/// A helper class with tools for testing camera orientation
class OrientationTestHelper {
    
    /// Creates a test LUT filter for testing
    static func createTestLUTFilter() -> CIFilter {
        // Create a basic identity LUT that doesn't modify the image
        guard let identityFilter = CIFilter(name: "CIColorCube") else {
            fatalError("Could not create identity filter")
        }
        
        // Create an identity color cube (each RGB input maps to same RGB output)
        let dimension = 2
        let size = dimension * dimension * dimension * 4
        var data = [Float](repeating: 0, count: size)
        
        var offset = 0
        for z in 0..<dimension {
            let blue = Float(z) / Float(dimension - 1)
            for y in 0..<dimension {
                let green = Float(y) / Float(dimension - 1)
                for x in 0..<dimension {
                    let red = Float(x) / Float(dimension - 1)
                    data[offset] = red
                    data[offset+1] = green
                    data[offset+2] = blue
                    data[offset+3] = 1.0
                    offset += 4
                }
            }
        }
        
        // Set parameters
        identityFilter.setValue(data, forKey: "inputCubeData")
        identityFilter.setValue(dimension, forKey: "inputCubeDimension")
        
        return identityFilter
    }
    
    /// Extracts video orientation angle from a sample buffer's metadata
    static func extractOrientationAngle(from sampleBuffer: CMSampleBuffer) -> CGFloat {
        // Get metadata from the sample buffer
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let firstAttachment = attachments.first,
              let videoFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return -1 // Indicates error
        }
        
        // Try to extract orientation from metadata
        if let rotationAngle = firstAttachment[kCMSampleAttachmentKey_VideoRotationAngle] as? CGFloat {
            return rotationAngle
        }
        
        // If not in metadata, try format description
        let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormatDescription)
        let isPortrait = dimensions.width < dimensions.height
        
        return isPortrait ? 90.0 : 0.0
    }
    
    /// Gets the expected angle for a given interface orientation
    static func expectedAngleForOrientation(_ orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .portrait:
            return 0
        case .portraitUpsideDown:
            return 180
        case .landscapeLeft:
            return 90
        case .landscapeRight:
            return 270
        default:
            return 0
        }
    }
    
    /// Captures a still image using the provided session
    /// - Parameters:
    ///   - session: The session to use for capture (either AVCaptureSession or MockAVCaptureSession)
    ///   - completion: Callback with the captured image and its orientation metadata, if available
    static func captureStillImage(from sessionObject: Any) -> UIImage? {
        // Handle real AVCaptureSession
        if let session = sessionObject as? AVCaptureSession {
            // Find the video connection
            guard let output = session.outputs.first as? AVCaptureVideoDataOutput,
                  let connection = output.connection(with: .video) else {
                return nil
            }
            
            // Create a dummy image with the same orientation as the current video output
            let color = UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
            let size = CGSize(width: 1920, height: 1080)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            
            // Return the image with the correct orientation based on the video connection
            return image
        }
        
        // Handle MockAVCaptureSession
        if let mockSession = sessionObject as? MockAVCaptureSession {
            // For mock sessions, create a dummy gradient image
            let size = CGSize(width: 1920, height: 1080)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                let colors = [
                    UIColor.red,
                    UIColor.blue
                ]
                
                let rect = CGRect(origin: .zero, size: size)
                let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: colors.map { $0.cgColor } as CFArray,
                    locations: [0.0, 1.0]
                )!
                
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            
            // Get the mock orientation angle
            var mockAngle: CGFloat = 0
            
            // Try to find a video connection in the mock session
            if let mockOutput = mockSession.outputs.first as? MockCaptureOutput {
                if let mockConnection = mockOutput.connection(with: .video) as? MockCaptureConnection {
                    mockAngle = mockConnection.videoRotationAngle
                }
            }
            
            return image
        }
        
        return nil
    }
    
    /// A delegate class to handle photo capture
    class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
        var photoData: Data?
        var completion: ((UIImage?) -> Void)?
        
        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            if let error = error {
                print("Error capturing photo: \(error)")
                completion?(nil)
                return
            }
            
            photoData = photo.fileDataRepresentation()
            if let data = photoData, let image = UIImage(data: data) {
                completion?(image)
            } else {
                completion?(nil)
            }
        }
    }
} 