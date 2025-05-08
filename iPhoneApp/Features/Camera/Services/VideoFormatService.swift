import AVFoundation
import os.log
import CoreMedia

protocol VideoFormatServiceDelegate: AnyObject {
    func didEncounterError(_ error: CameraError)
    func didUpdateFrameRate(_ frameRate: Double)
    func getCurrentFrameRate() -> Double?
    func getCurrentResolution() -> CameraViewModel.Resolution?
}

class VideoFormatService {
    private let logger = Logger(subsystem: "com.camera", category: "VideoFormatService")
    private weak var delegate: VideoFormatServiceDelegate?
    private var session: AVCaptureSession
    private var device: AVCaptureDevice?
    
    // Make this internal so CameraDeviceService can access it
    var isAppleLogEnabled = false
    // Remove the redundant computed property
    // var appleLogEnabled: Bool { isAppleLogEnabled }
    
    init(session: AVCaptureSession, delegate: VideoFormatServiceDelegate) {
        self.session = session
        self.delegate = delegate
    }
    
    func setDevice(_ device: AVCaptureDevice) {
        self.device = device
    }
    
    // Keep this internal setter
    func setAppleLogEnabled(_ enabled: Bool) {
        self.isAppleLogEnabled = enabled
    }
    
    // Add public methods to access delegate values safely
    func getCurrentFrameRateFromDelegate() -> Double? {
        return delegate?.getCurrentFrameRate()
    }
    
    func getCurrentResolutionFromDelegate() -> CameraViewModel.Resolution? {
        return delegate?.getCurrentResolution()
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
                throw CameraError.configurationFailed(message: "Failed to configure device for \(fps) fps recording.")
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
        // Find the current resolution from the delegate to ensure we maintain it
        guard let currentResolution = delegate?.getCurrentResolution() else {
            logger.warning("Could not get current resolution from delegate to find compatible format.")
            return findBestFormat(for: device, resolution: .uhd, frameRate: fps, requireAppleLog: isAppleLogEnabled) // Fallback to UHD
        }
        return findBestFormat(for: device, resolution: currentResolution, frameRate: fps, requireAppleLog: isAppleLogEnabled)
    }

    // ---> ADDED HELPER FUNCTION <---
    /// Calculates the specific CMTime duration for a given frame rate.
    func getFrameDuration(for fps: Double) -> CMTime {
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
            // Handle potential higher frame rates if added later
            if fps > 30 {
                 // Attempt standard calculation, log if unusual
                 logger.debug("Using standard CMTimeMake for potentially high frame rate: \(fps)")
                 frameDuration = CMTimeMake(value: 1, timescale: Int32(fps))
            } else {
                 // Default to 30fps if value is unexpected low
                 logger.warning("Unexpected FPS value \(fps) in getFrameDuration. Defaulting to 30fps duration.")
                 frameDuration = CMTime(value: 1, timescale: 30)
            }
        }
        logger.trace("[getFrameDuration] Calculated duration for \(fps) FPS: {\(frameDuration.value)/\(frameDuration.timescale)}")
        return frameDuration
    }
    // ---> END ADDED HELPER FUNCTION <---

    // New function to find the best format based on criteria
    func findBestFormat(for device: AVCaptureDevice, resolution: CameraViewModel.Resolution, frameRate: Double, requireAppleLog: Bool) -> AVCaptureDevice.Format? {
        logger.info("🔍 findBestFormat called for \(device.localizedName): Res=\(resolution.rawValue), FPS=\(frameRate), requireAppleLog=\(requireAppleLog)")
        let targetFps = frameRate
        let tolerance = 0.01 // Tolerance for floating point comparison
        let targetDimensions = resolution.dimensions
        logger.info("Target dimensions: \(targetDimensions.width)x\(targetDimensions.height), Target FPS: \(targetFps)")

        let allFormats = device.formats
        logger.debug("Total formats available on device: \(allFormats.count)")
        
        let availableFormats = allFormats.filter { format in
            // Check Resolution
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == targetDimensions.width && dimensions.height == targetDimensions.height else {
                // logger.trace("[findBestFormat Filter] Format \(format.uniqueID) rejected: Resolution mismatch (\(dimensions.width)x\(dimensions.height))")
                return false
            }
            // logger.trace("[findBestFormat Filter] Format \(format.uniqueID) passed resolution check.")

            // Check Frame Rate
            let supportsFrameRate = format.videoSupportedFrameRateRanges.contains { range in
                // logger.trace("Checking FPS range [\(range.minFrameRate)-\(range.maxFrameRate)] against \(targetFps)")
                // Handle specific fractional frame rates like 23.976 or 29.97
                if abs(targetFps - 23.976) < tolerance || abs(targetFps - 29.97) < tolerance {
                    return range.minFrameRate <= (targetFps - tolerance) && (targetFps + tolerance) <= range.maxFrameRate
                } else {
                    return range.minFrameRate <= targetFps && targetFps <= range.maxFrameRate
                }
            }
            guard supportsFrameRate else {
                // logger.trace("[findBestFormat Filter] Format \(format.uniqueID) rejected: FPS mismatch")
                return false
            }
            // logger.trace("[findBestFormat Filter] Format \(format.uniqueID) passed FPS check.")

            // Check Apple Log Support (if required)
            if requireAppleLog {
                guard format.supportedColorSpaces.contains(.appleLog) else {
                    // logger.trace("[findBestFormat Filter] Format \(format.uniqueID) rejected: Apple Log not supported")
                    return false
                }
                // logger.trace("[findBestFormat Filter] Format \(format.uniqueID) passed Apple Log check.")
            }
            
            // Check for specific desirable media subtypes (e.g., HEVC 10-bit)
            // Example: Prioritize 'hvc1' (HEVC) if available
            // let mediaType = CMFormatDescriptionGetMediaType(format.formatDescription)
            // let mediaSubType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            // if mediaType == kCMMediaType_Video && mediaSubType == kCMVideoCodecType_HEVC /* hvc1 */ {
                 // Optionally check for binned formats if needed, or other criteria
                 // logger.debug("Format \(format) is HEVC")
                 // let isBinned = format.isVideoBinned
                 // You could prioritize non-binned or binned based on needs
            // }

            // logger.trace("[findBestFormat Filter] Format \(format.uniqueID) passed all checks.")
            return true
        }
        
        logger.debug("Found \(availableFormats.count) formats matching criteria.")

        // Optional: Add further prioritization here if multiple formats match
        // e.g., prefer non-binned, higher bit depth, specific media subtypes
        // For now, just return the first match found by the filter.
        if let bestMatch = availableFormats.first {
             logger.info("✅ [findBestFormat] Found best match: \(bestMatch.description)")
             return bestMatch
        } else {
             logger.warning("⚠️ [findBestFormat] No format found matching criteria.")
             return nil
        }
    }
    
    // Modify to use internal device reference
    func reapplyColorSpaceSettings() throws {
        logger.info("🔄 [reapplyColorSpaceSettings] Attempting to reapply color space settings...")
        guard let device = self.device else {
            logger.warning("⚠️ [reapplyColorSpaceSettings] Failed: Internal device reference is nil.")
            throw CameraError.configurationFailed(message: "Device not available for reapplying color space.")
        }
        logger.info("🔄 [reapplyColorSpaceSettings] Using device: \(device.localizedName)")
        
        do {
            logger.debug("🔒 [reapplyColorSpaceSettings] Locking device for configuration...")
            try device.lockForConfiguration()
            defer {
                 logger.debug("🔓 [reapplyColorSpaceSettings] Unlocking device configuration.")
                 device.unlockForConfiguration() 
            }

            let currentFormat = device.activeFormat
            logger.info("🎨 [reapplyColorSpaceSettings] Current format: \(currentFormat.description)")
            let supportedSpaces = currentFormat.supportedColorSpaces.map { $0.rawValue }
            logger.info("🎨 [reapplyColorSpaceSettings] Supported spaces: \(supportedSpaces)")
            logger.info("🎨 [reapplyColorSpaceSettings] isAppleLogEnabled property: \(self.isAppleLogEnabled)")
            
            let defaultColorSpace: AVCaptureColorSpace = .sRGB
            var targetColorSpace: AVCaptureColorSpace = defaultColorSpace
            var reason: String = "Default"

            if isAppleLogEnabled && currentFormat.supportedColorSpaces.contains(.appleLog) {
                targetColorSpace = .appleLog
                reason = "Apple Log enabled and supported"
            } else if isAppleLogEnabled {
                targetColorSpace = defaultColorSpace // Fallback to default
                reason = "Apple Log enabled but NOT supported by format"
                logger.warning("⚠️ [reapplyColorSpaceSettings] Apple Log was enabled but is not supported by the current format (\(currentFormat.description)). Will attempt to set default color space (\(defaultColorSpace.rawValue)).")
            } else {
                targetColorSpace = defaultColorSpace
                reason = "Apple Log disabled"
            }
            
            logger.info("🎨 [reapplyColorSpaceSettings] Determined target color space: \(targetColorSpace.rawValue) (Reason: \(reason))")

            // *** ADDED: Explicitly set the active color space ***
            if device.activeColorSpace != targetColorSpace {
                logger.info("🎨 [reapplyColorSpaceSettings] Setting activeColorSpace to \(targetColorSpace.rawValue)...")
                device.activeColorSpace = targetColorSpace
                // Add verification
                if device.activeColorSpace == targetColorSpace {
                    logger.info("✅ [reapplyColorSpaceSettings] Successfully set activeColorSpace to \(targetColorSpace.rawValue).")
                } else {
                    logger.error("❌ [reapplyColorSpaceSettings] FAILED to set activeColorSpace to \(targetColorSpace.rawValue). Current space: \(device.activeColorSpace.rawValue)")
                    // Decide if we should throw an error here
                    throw CameraError.configurationFailed(message: "Failed to set target color space during reapply.")
                }
            } else {
                 logger.info("ℹ️ [reapplyColorSpaceSettings] activeColorSpace is already set to the target value (\(targetColorSpace.rawValue)).")
            }
            // *** END ADDED CODE ***
        } catch let error as CameraError {
             logger.error("❌ [reapplyColorSpaceSettings] Failed with CameraError: \(error.description)")
             throw error // Re-throw specific camera errors
        } catch {
            logger.error("❌ [reapplyColorSpaceSettings] Failed with generic error: \(error.localizedDescription)")
            throw CameraError.configurationFailed(message: "Failed to reapply color space: \(error.localizedDescription)")
        }
    }
    
    // Helper to set frame rate (extracted/adapted from updateFrameRate)
    private func updateFrameRateForCurrentFormat(fps: Double) throws {
        logger.info("⏱️ [updateFrameRateForCurrentFormat] Attempting to set FPS to \(fps)...")
        guard let device = device else {
             logger.error("⏱️ [updateFrameRateForCurrentFormat] Failed: Device not set.")
             throw CameraError.configurationFailed(message: "Device not set") 
        }
        
        let frameDuration: CMTime
        switch fps {
            case 23.976: frameDuration = CMTime(value: 1001, timescale: 24000)
            case 29.97: frameDuration = CMTime(value: 1001, timescale: 30000)
            // Add other cases as needed from updateFrameRate
            default: frameDuration = CMTime(value: 1, timescale: Int32(fps))
        }
        logger.debug("⏱️ [updateFrameRateForCurrentFormat] Calculated frame duration: \(frameDuration.value)/\(frameDuration.timescale)")

        // Check if the current format actually supports this frame rate
        logger.debug("⏱️ [updateFrameRateForCurrentFormat] Checking support in active format: \(device.activeFormat.description)")
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains { range in
             logger.trace("Checking range [\(range.minFrameRate)-\(range.maxFrameRate)] against \(fps)")
             return range.minFrameRate <= fps && fps <= range.maxFrameRate
        }

        if supported {
            logger.info("⏱️ [updateFrameRateForCurrentFormat] Format supports FPS \(fps). Attempting to set frame duration.")
            // Check if the device actually supports setting these frame durations
            do {
                logger.debug("🔒 [updateFrameRateForCurrentFormat] Locking device for configuration...")
                try device.lockForConfiguration()
                defer {
                     logger.debug("🔓 [updateFrameRateForCurrentFormat] Unlocking device configuration.")
                     device.unlockForConfiguration() 
                }
                // Check if durations are already correct to avoid unnecessary work/errors
                if device.activeVideoMinFrameDuration != frameDuration || device.activeVideoMaxFrameDuration != frameDuration {
                    logger.info("⏱️ [updateFrameRateForCurrentFormat] Setting activeVideoMin/MaxFrameDuration to \(frameDuration.value)/\(frameDuration.timescale)")
                    device.activeVideoMinFrameDuration = frameDuration
                    device.activeVideoMaxFrameDuration = frameDuration
                    // Verify if it was set (optional, but good for debugging)
                    if device.activeVideoMinFrameDuration == frameDuration && device.activeVideoMaxFrameDuration == frameDuration {
                        logger.info("✅ [updateFrameRateForCurrentFormat] Successfully set frame duration for FPS: \(fps)")
                    } else {
                        logger.error("❌ [updateFrameRateForCurrentFormat] Failed to set frame duration after attempt. Readback mismatch.")
                        throw CameraError.configurationFailed(message: "Could not verify frame rate duration change.")
                    }
                } else {
                    logger.info("ℹ️ [updateFrameRateForCurrentFormat] Frame duration already correct for FPS: \(fps)")
                }
            } catch {
                logger.error("❌ [updateFrameRateForCurrentFormat] Failed to lock/set frame duration for FPS \(fps): \(error.localizedDescription)")
                 throw CameraError.configurationFailed(message: "Could not set frame rate duration: \(error.localizedDescription)")
            }
        } else {
             logger.error("❌ [updateFrameRateForCurrentFormat] Current format does not support FPS \(fps). Configuration failed.")
             throw CameraError.configurationFailed(message: "Current format does not support FPS \(fps)")
        }
    }

    func configureAppleLog() async throws {
        logger.info("➡️ [configureAppleLog] Starting device preparation...")
        
        guard let device = device else {
            logger.error("❌ [configureAppleLog] Failed: No camera device available.")
            throw CameraError.configurationFailed
        }
        logger.debug("Using device: \(device.localizedName)")
        
        // Get current settings from delegate
        logger.debug("Fetching current settings from delegate...")
        guard let currentFPS = getCurrentFrameRateFromDelegate(),
              let currentResolution = getCurrentResolutionFromDelegate() else {
            logger.error("❌ [configureAppleLog] Failed: Could not get current FPS/Resolution from delegate.")
            throw CameraError.configurationFailed(message: "Missing current settings for Apple Log config.")
        }
        logger.info("Delegate settings: FPS=\(currentFPS), Resolution=\(currentResolution.rawValue)")
                
        do {
            logger.debug("🔒 [configureAppleLog] Locking device for configuration...")
            try device.lockForConfiguration()
             defer { 
                 logger.debug("🔓 [configureAppleLog] Unlocking device configuration.")
                 device.unlockForConfiguration() 
             }
            
            // --- Use findBestFormat --- 
            logger.info("🔍 [configureAppleLog] Searching for best format: Res=\(currentResolution.rawValue), FPS=\(currentFPS), AppleLog=true")
            guard let selectedFormat = findBestFormat(for: device, resolution: currentResolution, frameRate: currentFPS, requireAppleLog: true) else {
                logger.error("❌ [configureAppleLog] Failed: No suitable Apple Log format found matching current settings.")
                 throw CameraError.configurationFailed(message: "No format supports Apple Log with Res=\(currentResolution.rawValue), FPS=\(currentFPS)")
            }
            logger.info("✅ [configureAppleLog] Found suitable Apple Log format: \(selectedFormat.description)")
            // --- End findBestFormat usage ---
            
            // --- Set the format first --- 
            if device.activeFormat != selectedFormat {
                logger.info("🎞️ [configureAppleLog] Setting activeFormat...")
                device.activeFormat = selectedFormat
                logger.info("✅ [configureAppleLog] Set activeFormat to Apple Log compatible format.")
            } else {
                logger.info("ℹ️ [configureAppleLog] Active format is already the target Apple Log compatible format.")
            }
            // --- End set format ---

            // Configure color space through device configuration
            logger.info("🎨 [configureAppleLog] Configuring Apple Log color space...")
            let supportedColorSpaces = selectedFormat.supportedColorSpaces
            guard supportedColorSpaces.contains(.appleLog) else {
                logger.error("❌ [configureAppleLog] Selected format does not support Apple Log color space")
                throw CameraError.configurationFailed(message: "Selected format does not support Apple Log color space")
            }
            
            do {
                try device.lockForConfiguration()
                device.activeColorSpace = .appleLog
                device.unlockForConfiguration()
                logger.info("✅ [configureAppleLog] Successfully configured Apple Log color space")
            } catch {
                logger.error("❌ [configureAppleLog] Failed to configure color space: \(error)")
                throw CameraError.configurationFailed(message: "Failed to configure color space: \(error)")
            }

            // Verify the format supports Apple Log
            logger.debug("🧐 [configureAppleLog] Verifying selected format supports Apple Log...")
            guard selectedFormat.supportedColorSpaces.contains(.appleLog) else {
                logger.error("❌ [configureAppleLog] Failed: Selected format \(selectedFormat.description) does not support Apple Log despite findBestFormat.")
                throw CameraError.configurationFailed
            }
            logger.debug("✅ [configureAppleLog] Format supports Apple Log.")
            
            // Set frame duration
            logger.info("⏱️ [configureAppleLog] Calling updateFrameRateForCurrentFormat for FPS \(currentFPS)...")
            try updateFrameRateForCurrentFormat(fps: currentFPS)
            logger.info("✅ [configureAppleLog] Frame rate updated.")
            
            // Configure HDR
            logger.info("☀️ [configureAppleLog] Configuring HDR settings...")
            if selectedFormat.isVideoHDRSupported {
                logger.debug("HDR Supported. Setting automaticallyAdjustsVideoHDREnabled=false, isVideoHDREnabled=true")
                device.automaticallyAdjustsVideoHDREnabled = false 
                device.isVideoHDREnabled = true
                logger.info("✅ [configureAppleLog] Enabled HDR video mode for Apple Log.")
            } else {
                logger.debug("HDR NOT Supported. Setting automaticallyAdjustsVideoHDREnabled=true, isVideoHDREnabled=false")
                device.automaticallyAdjustsVideoHDREnabled = true
                device.isVideoHDREnabled = false
                 logger.info("ℹ️ [configureAppleLog] Selected Apple Log format does not support HDR video.")
            }
            
            logger.info("✅ [configureAppleLog] Successfully prepared device for Apple Log format.")
            
        } catch let error as CameraError {
             logger.error("❌ [configureAppleLog] Failed during device preparation: \(error.description)")
             throw error // Re-throw specific camera errors
        } catch {
            logger.error("❌ [configureAppleLog] Failed during device preparation with generic error: \(error.localizedDescription)")
            throw CameraError.configurationFailed(message: "Configuring Apple Log failed: \(error.localizedDescription)")
        }
        logger.info("🏁 [configureAppleLog] Finished device preparation process.")
    }
    
    func resetAppleLog() async throws {
        logger.info("➡️ [resetAppleLog] Starting device preparation for reset...")
        
        guard let device = device else {
            logger.error("❌ [resetAppleLog] Failed: No camera device available.")
            throw CameraError.configurationFailed
        }
         logger.debug("Using device: \(device.localizedName)")

        // Get current settings from delegate for format selection
        logger.debug("Fetching current settings from delegate...")
        guard let currentFPS = getCurrentFrameRateFromDelegate(),
              let currentResolution = getCurrentResolutionFromDelegate() else {
            logger.error("❌ [resetAppleLog] Failed: Could not get current FPS/Resolution from delegate.")
            throw CameraError.configurationFailed(message: "Missing current settings for Apple Log reset.")
        }
        logger.info("Delegate settings: FPS=\(currentFPS), Resolution=\(currentResolution.rawValue)")
                
        do {
            logger.debug("🔒 [resetAppleLog] Locking device for configuration...")
            try device.lockForConfiguration()
            defer { 
                 logger.debug("🔓 [resetAppleLog] Unlocking device configuration.")
                 device.unlockForConfiguration() 
             }
            
            // Find a suitable non-Apple Log format matching current settings
            logger.info("🔍 [resetAppleLog] Searching for best format: Res=\(currentResolution.rawValue), FPS=\(currentFPS), AppleLog=false")
            guard let selectedFormat = findBestFormat(for: device, resolution: currentResolution, frameRate: currentFPS, requireAppleLog: false) else {
                logger.error("❌ [resetAppleLog] Failed: No suitable non-Apple Log format found matching current settings.")
                throw CameraError.configurationFailed(message: "No non-Log format found for Res=\(currentResolution.rawValue), FPS=\(currentFPS)")
            }
            logger.info("✅ [resetAppleLog] Found suitable non-Apple Log format: \(selectedFormat.description)")
            
            // Set the format
            if device.activeFormat != selectedFormat {
                 logger.info("🎞️ [resetAppleLog] Setting activeFormat...")
                 device.activeFormat = selectedFormat
                 logger.info("✅ [resetAppleLog] Applied best non-Log format.")
             } else {
                 logger.info("ℹ️ [resetAppleLog] Active format is already the target format.")
             }
            
            // Explicitly set the color space to standard
            logger.info("🎨 [resetAppleLog] Setting activeColorSpace to standard...")
            let supportedColorSpaces = selectedFormat.supportedColorSpaces
            guard supportedColorSpaces.contains(.sRGB) else {
                logger.error("❌ [resetAppleLog] Selected format does not support sRGB color space")
                throw CameraError.configurationFailed(message: "Format does not support sRGB color space")
            }
            
            device.activeColorSpace = .sRGB
            
            // Verify the color space was reset
            if device.activeColorSpace == .sRGB {
                logger.info("✅ [resetAppleLog] Verified activeColorSpace is now standard.")
            } else {
                logger.error("❌ [resetAppleLog] FAILED verification: activeColorSpace is \(device.activeColorSpace.rawValue), not standard, after explicit set.")
                throw CameraError.configurationFailed(message: "Failed to verify standard color space after explicit set.")
            }
            
            // Set frame duration
            logger.info("⏱️ [resetAppleLog] Calling updateFrameRateForCurrentFormat for FPS \(currentFPS)...")
            try updateFrameRateForCurrentFormat(fps: currentFPS)
            logger.info("✅ [resetAppleLog] Frame rate updated.")
            
            // Updated log message slightly to reflect HDR is no longer handled here
            logger.info("✅ [resetAppleLog] Successfully prepared device format/colorspace/framerate for reset.") 
            
        } catch let error as CameraError {
             logger.error("❌ [resetAppleLog] Failed during device preparation: \(error.description)")
             throw error
        } catch {
            logger.error("❌ [resetAppleLog] Failed during device preparation with generic error: \(error.localizedDescription)")
            throw CameraError.configurationFailed(message: "Resetting Apple Log failed: \(error.localizedDescription)")
        }
         logger.info("🏁 [resetAppleLog] Finished device preparation process.")
    }
} 