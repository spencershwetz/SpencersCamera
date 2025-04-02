import AVFoundation
import os.log
import CoreMedia

protocol VideoFormatServiceDelegate: AnyObject {
    func didEncounterError(_ error: CameraError)
    func didUpdateFrameRate(_ frameRate: Double)
}

class VideoFormatService {
    private let logger = Logger(subsystem: "com.camera", category: "VideoFormatService")
    private weak var delegate: VideoFormatServiceDelegate?
    private var session: AVCaptureSession
    private var device: AVCaptureDevice?
    
    private var isAppleLogEnabled = false
    
    init(session: AVCaptureSession, delegate: VideoFormatServiceDelegate) {
        self.session = session
        self.delegate = delegate
    }
    
    func setDevice(_ device: AVCaptureDevice) {
        self.device = device
    }
    
    func setAppleLogEnabled(_ enabled: Bool) {
        self.isAppleLogEnabled = enabled
    }
    
    func updateCameraFormat(for resolution: CameraViewModel.Resolution) async throws {
        guard let device = device else { 
            logger.error("No camera device available")
            throw CameraError.configurationFailed 
        }
        
        logger.info("Updating camera format to \(resolution.rawValue)")
        
        let wasRunning = session.isRunning
        if wasRunning {
            session.stopRunning()
        }
        
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            // Find all formats that match our resolution
            let matchingFormats = device.formats.filter { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dimensions.width == resolution.dimensions.width &&
                       dimensions.height == resolution.dimensions.height
            }
            
            logger.info("Found \(matchingFormats.count) matching formats")
            
            // Find the best format that supports current frame rate
            let frameRate = device.activeVideoMinFrameDuration.timescale > 0 ?
                Double(device.activeVideoMinFrameDuration.timescale) / Double(device.activeVideoMinFrameDuration.value) :
                30.0
            
            let bestFormat = matchingFormats.first { format in
                format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate...range.maxFrameRate ~= frameRate
                }
            } ?? matchingFormats.first
            
            guard let selectedFormat = bestFormat else {
                logger.error("No compatible format found for resolution \(resolution.rawValue)")
                if wasRunning {
                    session.startRunning()
                }
                throw CameraError.configurationFailed
            }
            
            // Begin configuration
            session.beginConfiguration()
            
            // Set the format
            device.activeFormat = selectedFormat
            
            // Set the frame duration
            let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            
            // If Apple Log is enabled, set the color space
            if isAppleLogEnabled && selectedFormat.supportedColorSpaces.contains(.appleLog) {
                device.activeColorSpace = .appleLog
                logger.info("Applied Apple Log color space")
                
                // Post notification for color space change with specific info
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ColorSpaceChanged"),
                        object: nil,
                        userInfo: ["colorSpace": "appleLog"]
                    )
                    
                    // Post a second notification after a short delay to ensure views can respond
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("ColorSpaceChanged"),
                            object: nil,
                            userInfo: ["colorSpace": "appleLog"]
                        )
                    }
                }
            } else {
                device.activeColorSpace = .sRGB
                logger.info("Applied sRGB color space")
                
                // Post notification for color space change with specific info
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ColorSpaceChanged"),
                        object: nil,
                        userInfo: ["colorSpace": "sRGB"]
                    )
                    
                    // Post a second notification after a short delay to ensure views can respond
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("ColorSpaceChanged"),
                            object: nil,
                            userInfo: ["colorSpace": "sRGB"]
                        )
                    }
                }
            }
            
            // Commit the configuration
            session.commitConfiguration()
            
            // Restore session state if it was running
            if wasRunning {
                session.startRunning()
            }
            
            logger.info("Camera format updated successfully")
            
        } catch {
            logger.error("Error updating camera format: \(error.localizedDescription)")
            session.commitConfiguration()
            
            if wasRunning {
                session.startRunning()
            }
            
            throw error
        }
    }
    
    func updateFrameRate(_ fps: Double) throws {
        guard let device = device else { 
            logger.error("No camera device available")
            throw CameraError.configurationFailed 
        }
        
        do {
            guard let compatibleFormat = findCompatibleFormat(for: fps) else {
                logger.error("No compatible format found for \(fps) fps")
                throw CameraError.configurationFailed(message: "This device doesn't support \(fps) fps recording")
            }
            
            try device.lockForConfiguration()
            
            if device.activeFormat != compatibleFormat {
                logger.info("Switching to compatible format for \(fps) fps")
                device.activeFormat = compatibleFormat
            }
            
            let frameDuration: CMTime
            switch fps {
            case 23.976:
                frameDuration = CMTime(value: 1001, timescale: 24000)
            case 29.97:
                frameDuration = CMTime(value: 1001, timescale: 30000)
            case 24:
                frameDuration = CMTime(value: 1, timescale: 24)
            case 25:
                frameDuration = CMTime(value: 1, timescale: 25)
            case 30:
                frameDuration = CMTime(value: 1, timescale: 30)
            default:
                frameDuration = CMTimeMake(value: 1, timescale: Int32(fps))
            }
            
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            
            device.unlockForConfiguration()
            
            delegate?.didUpdateFrameRate(fps)
            logger.info("Frame rate updated to \(fps) fps")
            
        } catch {
            logger.error("Frame rate error: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed(message: "Failed to set \(fps) fps: \(error.localizedDescription)"))
            throw error
        }
    }
    
    private func findCompatibleFormat(for fps: Double) -> AVCaptureDevice.Format? {
        guard let device = device else { return nil }
        
        let targetFps = fps
        let tolerance = 0.01
        
        let formats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let isHighRes = dimensions.width >= 1920
            let supportsFrameRate = format.videoSupportedFrameRateRanges.contains { range in
                if abs(targetFps - 23.976) < 0.001 {
                    return range.minFrameRate <= (targetFps - tolerance) &&
                           (targetFps + tolerance) <= range.maxFrameRate
                } else {
                    return range.minFrameRate <= targetFps && targetFps <= range.maxFrameRate
                }
            }
            
            if isAppleLogEnabled {
                return isHighRes && supportsFrameRate && format.supportedColorSpaces.contains(.appleLog)
            }
            return isHighRes && supportsFrameRate
        }
        
        return formats.first
    }
    
    func configureAppleLog() async throws {
        logger.info("Configuring Apple Log")
        
        guard let device = device else {
            logger.error("No camera device available")
            throw CameraError.configurationFailed
        }
        
        let wasRunning = session.isRunning
        if wasRunning {
            session.stopRunning()
        }
        
        do {
            try await Task.sleep(for: .milliseconds(100))
            
            // Lock device configuration
            do {
                try device.lockForConfiguration()
            } catch {
                if wasRunning {
                    session.startRunning()
                }
                throw CameraError.configurationFailed
            }
            
            defer {
                device.unlockForConfiguration()
            }
            
            // Log device information
            logger.info("Configuring Apple Log for device: \(device.localizedName)")
            logger.info("Current device type: \(device.deviceType.rawValue)")
            
            // Find formats that support Apple Log
            let formats = device.formats.filter { format in
                let desc = format.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
                
                // Log format details for debugging
                if hasAppleLog {
                    logger.info("Found format with Apple Log support:")
                    logger.info("- Dimensions: \(dimensions.width)x\(dimensions.height)")
                    logger.info("- Color Spaces: \(format.supportedColorSpaces)")
                    logger.info("- Media Subtype: \(CMFormatDescriptionGetMediaSubType(desc))")
                }
                
                // For ultra-wide lens, we need to be more lenient with resolution requirements
                let isUltraWide = device.deviceType == .builtInUltraWideCamera
                let resolution = dimensions.width >= (isUltraWide ? 1280 : 1920) &&
                               dimensions.height >= (isUltraWide ? 720 : 1080)
                
                return hasAppleLog && resolution
            }
            
            // Sort formats by resolution
            let sortedFormats = formats.sorted { (format1: AVCaptureDevice.Format, format2: AVCaptureDevice.Format) -> Bool in
                let dim1 = CMVideoFormatDescriptionGetDimensions(format1.formatDescription)
                let dim2 = CMVideoFormatDescriptionGetDimensions(format2.formatDescription)
                return dim1.width * dim1.height > dim2.width * dim2.height
            }
            
            guard let selectedFormat = sortedFormats.first else {
                logger.error("No suitable Apple Log format found")
                logger.info("Total available formats: \(device.formats.count)")
                device.formats.prefix(3).forEach { format in
                    let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    logger.info("Available format: \(dim.width)x\(dim.height), Color spaces: \(format.supportedColorSpaces)")
                }
                if wasRunning {
                    session.startRunning()
                }
                throw CameraError.configurationFailed
            }
            
            session.beginConfiguration()
            
            // Set the format
            device.activeFormat = selectedFormat
            
            // Verify format supports Apple Log before setting
            if selectedFormat.supportedColorSpaces.contains(.appleLog) {
                device.activeColorSpace = .appleLog
                logger.info("Successfully set Apple Log color space")
                
                let dimensions = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription)
                logger.info("Active format: \(dimensions.width)x\(dimensions.height)")
            } else {
                logger.error("Selected format does not support Apple Log")
                session.commitConfiguration()
                if wasRunning {
                    session.startRunning()
                }
                throw CameraError.configurationFailed
            }
            
            // Get current frame rate
            let frameRate = device.activeVideoMinFrameDuration.timescale > 0 ?
                Double(device.activeVideoMinFrameDuration.timescale) / Double(device.activeVideoMinFrameDuration.value) :
                30.0
            
            // Set frame duration
            let duration = CMTimeMake(value: 1000, timescale: Int32(frameRate * 1000))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            
            // Set color space
            device.activeColorSpace = .appleLog
            logger.info("Set color space to Apple Log")
            
            // Post notification for color space change with specific info
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ColorSpaceChanged"),
                    object: nil,
                    userInfo: ["colorSpace": "appleLog"]
                )
                
                // Post a second notification after a short delay to ensure views can respond
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ColorSpaceChanged"),
                        object: nil,
                        userInfo: ["colorSpace": "appleLog"]
                    )
                }
            }
            
            session.commitConfiguration()
            
            if wasRunning {
                session.startRunning()
            }
            
            logger.info("Successfully configured Apple Log format")
            
        } catch {
            logger.error("Error configuring Apple Log: \(error.localizedDescription)")
            if wasRunning {
                session.startRunning()
            }
            throw error
        }
    }
    
    func resetAppleLog() async throws {
        logger.info("Resetting Apple Log")
        
        guard let device = device else {
            logger.error("No camera device available")
            throw CameraError.configurationFailed
        }
        
        do {
            session.stopRunning()
            
            try await Task.sleep(for: .milliseconds(100))
            session.beginConfiguration()
            
            do {
                try device.lockForConfiguration()
            } catch {
                throw CameraError.configurationFailed
            }
            
            defer {
                device.unlockForConfiguration()
                session.commitConfiguration()
                session.startRunning()
            }
            
            // Find a format that matches our resolution
            let dims = CameraViewModel.Resolution.uhd.dimensions
            let formats = device.formats.filter { format in
                let desc = format.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                return dimensions.width >= dims.width && dimensions.height >= dims.height
            }
            
            guard let selectedFormat = formats.first else {
                logger.error("No suitable format found")
                throw CameraError.configurationFailed
            }
            
            // Set the format
            device.activeFormat = selectedFormat
            
            // Get current frame rate
            let frameRate = device.activeVideoMinFrameDuration.timescale > 0 ?
                Double(device.activeVideoMinFrameDuration.timescale) / Double(device.activeVideoMinFrameDuration.value) :
                30.0
            
            // Set frame duration
            let duration = CMTimeMake(value: 1000, timescale: Int32(frameRate * 1000))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            
            // Reset HDR settings
            if selectedFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = true
                logger.info("Reset HDR settings")
            }
            
            // Reset color space
            device.activeColorSpace = .sRGB
            logger.info("Reset color space to sRGB")
            
            // Post notification for color space change with specific info
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ColorSpaceChanged"),
                    object: nil,
                    userInfo: ["colorSpace": "sRGB"]
                )
                
                // Post a second notification after a short delay to ensure views can respond
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ColorSpaceChanged"),
                        object: nil,
                        userInfo: ["colorSpace": "sRGB"]
                    )
                }
            }
            
            logger.info("Successfully reset Apple Log format")
            
        } catch {
            logger.error("Error resetting Apple Log: \(error.localizedDescription)")
            throw error
        }
    }
} 