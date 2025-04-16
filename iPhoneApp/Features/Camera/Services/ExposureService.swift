import AVFoundation
import os.log
import CoreMedia

protocol ExposureServiceDelegate: AnyObject {
    func didUpdateWhiteBalance(_ temperature: Float)
    func didUpdateISO(_ iso: Float)
    func didUpdateShutterSpeed(_ speed: CMTime)
    func didEncounterError(_ error: CameraError)
}

class ExposureService {
    private let logger = Logger(subsystem: "com.camera", category: "ExposureService")
    private weak var delegate: ExposureServiceDelegate?
    
    private var device: AVCaptureDevice?
    private var isAutoExposureEnabled = true
    
    init(delegate: ExposureServiceDelegate) {
        self.delegate = delegate
    }
    
    func setDevice(_ device: AVCaptureDevice) {
        self.device = device
    }
    
    func updateWhiteBalance(_ temperature: Float) {
        guard let device = device else { 
            logger.error("No camera device available")
            return 
        }
        
        do {
            try device.lockForConfiguration()
            let tnt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0.0)
            var gains = device.deviceWhiteBalanceGains(for: tnt)
            let maxGain = device.maxWhiteBalanceGain
            
            gains.redGain   = min(max(1.0, gains.redGain), maxGain)
            gains.greenGain = min(max(1.0, gains.greenGain), maxGain)
            gains.blueGain  = min(max(1.0, gains.blueGain), maxGain)
            
            device.setWhiteBalanceModeLocked(with: gains) { _ in }
            device.unlockForConfiguration()
            
            delegate?.didUpdateWhiteBalance(temperature)
        } catch {
            logger.error("White balance error: \(error.localizedDescription)")
            delegate?.didEncounterError(.whiteBalanceError)
        }
    }
    
    func updateISO(_ iso: Float) {
        guard let device = device else { 
            logger.error("No camera device available")
            return 
        }
        
        // Get the current device's supported ISO range
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        
        logger.debug("ISO update requested to \(iso). Device supports range: \(minISO) to \(maxISO)")
        
        // Ensure the ISO value is within the supported range
        let clampedISO = min(max(minISO, iso), maxISO)
        
        // Log if clamping occurred
        if clampedISO != iso {
            logger.debug("Clamped ISO from \(iso) to \(clampedISO) to stay within device limits")
        }
        
        do {
            try device.lockForConfiguration()
            
            // Set exposure mode to custom
            if device.isExposureModeSupported(.custom) {
                device.exposureMode = .custom
                device.setExposureModeCustom(duration: device.exposureDuration, iso: clampedISO) { _ in }
            }
            
            device.unlockForConfiguration()
            
            // Update the delegate with the actual value used
            delegate?.didUpdateISO(clampedISO)
            logger.debug("Successfully set ISO to \(clampedISO)")
        } catch {
            logger.error("ISO update error: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed)
        }
    }
    
    func updateShutterSpeed(_ speed: CMTime) {
        guard let device = device else { 
            logger.error("No camera device available")
            return 
        }
        
        do {
            try device.lockForConfiguration()
            
            // Get the current device's supported ISO range
            let minISO = device.activeFormat.minISO
            let maxISO = device.activeFormat.maxISO
            
            // Get current ISO value
            let currentISO = device.iso
            
            // Ensure the ISO value is within the supported range
            let clampedISO = min(max(minISO, currentISO), maxISO)
            
            // If ISO is 0 or outside valid range, use min ISO as fallback
            let safeISO = clampedISO <= 0 ? minISO : clampedISO
            
            if device.isExposureModeSupported(.custom) {
                device.exposureMode = .custom
                device.setExposureModeCustom(duration: speed, iso: safeISO) { _ in }
            }
            
            device.unlockForConfiguration()
            
            delegate?.didUpdateShutterSpeed(speed)
            
            // If we had to correct ISO, update that too
            if safeISO != currentISO {
                delegate?.didUpdateISO(safeISO)
            }
        } catch {
            logger.error("Shutter speed error: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed)
        }
    }
    
    func updateShutterAngle(_ angle: Double, frameRate: Double) {
        let clampedAngle = min(max(angle, 1.1), 360.0)
        let duration = (clampedAngle / 360.0) * (1.0 / frameRate)
        let time = CMTimeMakeWithSeconds(duration, preferredTimescale: 1000000)
        updateShutterSpeed(time)
    }
    
    func setAutoExposureEnabled(_ enabled: Bool) {
        isAutoExposureEnabled = enabled
        updateExposureMode()
    }
    
    private func updateExposureMode() {
        guard let device = device else { 
            logger.error("No camera device available")
            return 
        }
        
        do {
            try device.lockForConfiguration()
            
            if isAutoExposureEnabled {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                    logger.info("Auto exposure enabled")
                }
            } else {
                if device.isExposureModeSupported(.custom) {
                    device.exposureMode = .custom
                    
                    // Double check ISO range limits
                    let minISO = device.activeFormat.minISO
                    let maxISO = device.activeFormat.maxISO
                    let currentISO = device.iso
                    let clampedISO = min(max(minISO, currentISO), maxISO)
                    
                    device.setExposureModeCustom(duration: device.exposureDuration,
                                                 iso: clampedISO) { _ in }
                    logger.info("Manual exposure enabled with ISO \(clampedISO)")
                    
                    // If we had to adjust the ISO, update the delegate
                    if clampedISO != currentISO {
                        delegate?.didUpdateISO(clampedISO)
                    }
                }
            }
            
            device.unlockForConfiguration()
        } catch {
            logger.error("Error setting exposure mode: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed)
        }
    }
    
    /// Sets the exposure lock on the capture device.
    /// - Parameter locked: A Boolean value indicating whether to lock the exposure.
    func setExposureLock(locked: Bool) {
        guard let device = device else {
            logger.error("Cannot set exposure lock: No camera device available")
            delegate?.didEncounterError(.configurationFailed(message: "No camera device for exposure lock"))
            return
        }

        // Determine the target mode based on lock state and current settings
        let targetMode: AVCaptureDevice.ExposureMode
        if locked {
            targetMode = .locked
        } else {
            // If unlocking, revert to auto or custom based on isAutoExposureEnabled
            if isAutoExposureEnabled {
                targetMode = .continuousAutoExposure
            } else {
                targetMode = .custom
                // Note: When switching to .custom, device might reset ISO/shutter.
                // Ideally, we should re-apply the last known manual settings here,
                // but that requires ExposureService to store them.
                // For now, just switching to .custom might suffice, but could be improved.
            }
        }
        
        // Check if the target mode is supported
        guard device.isExposureModeSupported(targetMode) else {
            logger.warning("Exposure mode \(String(describing: targetMode)) is not supported by the current device.")
            // Optionally, inform the delegate or handle this case appropriately.
            // For now, we just log and return, leaving the mode unchanged.
            return
        }
        
        // Only apply if the mode needs to change
        if device.exposureMode != targetMode {
            do {
                try device.lockForConfiguration()
                device.exposureMode = targetMode
                device.unlockForConfiguration()
                logger.info("Successfully set exposure mode to \(String(describing: targetMode))")
            } catch {
                logger.error("Error setting exposure mode to \(String(describing: targetMode)): \(error.localizedDescription)")
                delegate?.didEncounterError(.configurationFailed(message: "Failed to set exposure mode: \(error.localizedDescription)"))
            }
        } else {
            logger.info("Exposure mode is already \(String(describing: targetMode)), no change needed.")
        }
    }
    
    func updateTint(_ tintValue: Double, currentWhiteBalance: Float) {
        guard let device = device else { 
            logger.error("No camera device available")
            return 
        }
        
        let tintRange = (-150.0...150.0)
        let clampedTint = min(max(tintValue, tintRange.lowerBound), tintRange.upperBound)
        
        do {
            try device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
                
                let currentGains = device.deviceWhiteBalanceGains
                var newGains = currentGains
                let tintScale = clampedTint / 150.0
                
                if tintScale > 0 {
                    newGains.greenGain = currentGains.greenGain * (1.0 + Float(tintScale))
                } else {
                    let magentaScale = 1.0 + Float(abs(tintScale))
                    newGains.redGain = currentGains.redGain * magentaScale
                    newGains.blueGain = currentGains.blueGain * magentaScale
                }
                
                let maxGain = device.maxWhiteBalanceGain
                newGains.redGain = min(max(1.0, newGains.redGain), maxGain)
                newGains.greenGain = min(max(1.0, newGains.greenGain), maxGain)
                newGains.blueGain = min(max(1.0, newGains.blueGain), maxGain)
                
                device.setWhiteBalanceModeLocked(with: newGains) { _ in }
            }
            device.unlockForConfiguration()
        } catch {
            logger.error("Error setting tint: \(error.localizedDescription)")
            delegate?.didEncounterError(.whiteBalanceError)
        }
    }
} 