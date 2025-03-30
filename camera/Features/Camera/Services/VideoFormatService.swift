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
            } else {
                device.activeColorSpace = .sRGB
                logger.info("Applied sRGB color space")
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
            
            // Find a format that supports Apple Log
            let formats = device.formats.filter { format in
                let desc = format.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
                let resolution = CameraViewModel.Resolution.uhd.dimensions
                let matchesResolution = dimensions.width >= resolution.width &&
                                      dimensions.height >= resolution.height
                return hasAppleLog && matchesResolution
            }
            
            guard let selectedFormat = formats.first else {
                logger.error("No suitable Apple Log format found")
                throw CameraError.configurationFailed
            }
            
            logger.info("Found suitable Apple Log format")
            
            // Set the format first
            device.activeFormat = selectedFormat
            
            // Verify the format supports Apple Log
            guard selectedFormat.supportedColorSpaces.contains(.appleLog) else {
                logger.error("Selected format does not support Apple Log")
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
            
            // Configure HDR if supported
            if selectedFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = true
                logger.info("Enabled HDR support")
            }
            
            // Set color space
            device.activeColorSpace = .appleLog
            logger.info("Set color space to Apple Log")
            
            logger.info("Successfully configured Apple Log format")
            
        } catch {
            logger.error("Error configuring Apple Log: \(error.localizedDescription)")
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
            
            logger.info("Successfully reset Apple Log format")
            
        } catch {
            logger.error("Error resetting Apple Log: \(error.localizedDescription)")
            throw error
        }
    }
} 