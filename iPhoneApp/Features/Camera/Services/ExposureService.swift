import AVFoundation
import os.log
import CoreMedia

protocol ExposureServiceDelegate: AnyObject {
    func didUpdateWhiteBalance(_ temperature: Float)
    func didUpdateISO(_ iso: Float)
    func didUpdateShutterSpeed(_ speed: CMTime)
    func didEncounterError(_ error: CameraError)
}

// Inherit from NSObject to support KVO
class ExposureService: NSObject {
    private let logger = Logger(subsystem: "com.camera", category: "ExposureService")
    private weak var delegate: ExposureServiceDelegate?
    
    private var device: AVCaptureDevice?
    private var isAutoExposureEnabled = true
    
    // KVO Observation tokens
    private var isoObservation: NSKeyValueObservation?
    private var exposureDurationObservation: NSKeyValueObservation?
    private var whiteBalanceGainsObservation: NSKeyValueObservation?
    
    init(delegate: ExposureServiceDelegate) {
        self.delegate = delegate
    }
    
    // Clean up observers on deinitialization
    deinit {
        removeDeviceObservers()
        logger.info("ExposureService deinitialized, observers removed.")
    }
    
    func setDevice(_ device: AVCaptureDevice?) {
        logger.info("ExposureService setDevice called with: \(device?.localizedName ?? "nil")")
        removeDeviceObservers()
        self.device = device
        if let device = device {
            logger.info("ExposureService setupDeviceObservers called for device: \(device.localizedName)")
            setupDeviceObservers(for: device)
            self.isAutoExposureEnabled = (device.exposureMode == .continuousAutoExposure)
            logger.info("Initial auto exposure state set to: \(self.isAutoExposureEnabled)")
        } else {
             logger.info("ExposureService setDevice called with nil, observers removed.")
        }
    }
    
    /// Helper function to get the name of the currently configured device.
    func getCurrentDeviceName() -> String {
        return device?.localizedName ?? "No Device Set"
    }
    
    // MARK: - KVO Setup and Teardown
    
    private func setupDeviceObservers(for device: AVCaptureDevice) {
        logger.info("Setting up KVO observers for device: \(device.localizedName)")
        
        // Observe ISO changes
        isoObservation = device.observe(\.iso, options: [.new]) { [weak self] device, change in
            guard let self = self, let newISO = change.newValue else { return }
            // Report if in auto, locked, OR custom mode (since ISO can auto-adjust in custom mode too)
            if device.exposureMode == .continuousAutoExposure || 
               device.exposureMode == .locked || 
               device.exposureMode == .custom {
                // logger.debug("[KVO] ISO changed to: \(newISO) while mode is \(device.exposureMode.rawValue)")
                // Update delegate on the main thread as it might trigger UI updates
                DispatchQueue.main.async {
                    self.delegate?.didUpdateISO(newISO)
                }
            }
        }
        
        // Observe exposure duration (shutter speed) changes
        exposureDurationObservation = device.observe(\.exposureDuration, options: [.new]) { [weak self] device, change in
            guard let self = self, let newDuration = change.newValue else { return }
            if device.exposureMode == .continuousAutoExposure || device.exposureMode == .locked {
                // logger.debug("[KVO] Exposure duration changed to: \(CMTimeGetSeconds(newDuration))")
                DispatchQueue.main.async {
                    self.delegate?.didUpdateShutterSpeed(newDuration)
                }
            }
        }
        
        // Observe white balance gains changes
        whiteBalanceGainsObservation = device.observe(\.deviceWhiteBalanceGains, options: [.new]) { [weak self] device, change in
            guard let self = self, let newGains = change.newValue else { return }
            // Always report WB changes if the delegate is available, regardless of mode?
            // Let the ViewModel decide if it cares based on its own state.
            // if device.whiteBalanceMode == .continuousAutoWhiteBalance || device.whiteBalanceMode == .locked {
                 // Convert gains to temperature
                let tempAndTint = device.temperatureAndTintValues(for: newGains)
                let temperature = tempAndTint.temperature
                logger.debug("[KVO] White balance gains changed, corresponding temperature: \(temperature)")
                DispatchQueue.main.async {
                    self.delegate?.didUpdateWhiteBalance(temperature)
                }
            // }
        }
        
        // Report initial values immediately after setting observers
        reportCurrentDeviceValues()
    }
    
    private func removeDeviceObservers() {
        logger.info("Removing KVO observers. Stack trace: \(Thread.callStackSymbols.joined(separator: "\\n"))")
        isoObservation?.invalidate()
        exposureDurationObservation?.invalidate()
        whiteBalanceGainsObservation?.invalidate()
        isoObservation = nil
        exposureDurationObservation = nil
        whiteBalanceGainsObservation = nil
    }

    /// Helper function to report the current values after setting observers or device change. Internal access needed by ViewModel.
    func reportCurrentDeviceValues() {
        guard let device = device else { return }
        logger.debug("Reporting initial device values after observer setup.")
        DispatchQueue.main.async { [weak self] in
             guard let self = self else { return }
             // Report ISO - Allow reporting in .custom mode as well
             if device.exposureMode == .continuousAutoExposure || 
                device.exposureMode == .locked || 
                device.exposureMode == .custom { // <-- Allow reporting in .custom mode
                 self.delegate?.didUpdateISO(device.iso)
                 logger.debug("Reporting current ISO: \(device.iso) in mode \(device.exposureMode.rawValue)")
             }
             // Report Shutter Speed - Allow reporting in .custom mode as well
             if device.exposureMode == .continuousAutoExposure || 
                device.exposureMode == .locked || 
                device.exposureMode == .custom { // <-- Allow reporting in .custom mode
                 self.delegate?.didUpdateShutterSpeed(device.exposureDuration)
                  logger.debug("Reporting current Shutter: \(CMTimeGetSeconds(device.exposureDuration))s in mode \(device.exposureMode.rawValue)")
             }
             // Report White Balance
             if device.whiteBalanceMode == .continuousAutoWhiteBalance || device.whiteBalanceMode == .locked {
                 let tempAndTint = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                 self.delegate?.didUpdateWhiteBalance(tempAndTint.temperature)
             }
        }
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
            
            // Set mode to locked when manually setting WB
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
                device.setWhiteBalanceModeLocked(with: gains) { [weak self] _ in
                    // Report the value back via delegate *after* it's set
                    DispatchQueue.main.async {
                        self?.delegate?.didUpdateWhiteBalance(temperature)
                    }
                }
            } else {
                 logger.warning("Locked white balance mode not supported.")
            }
            device.unlockForConfiguration()

            // Delegate call moved inside completion handler to reflect actual set value timing
            // delegate?.didUpdateWhiteBalance(temperature) 
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
                device.setExposureModeCustom(duration: device.exposureDuration, iso: clampedISO) { [weak self] _ in
                     // Report the value back via delegate *after* it's set
                     DispatchQueue.main.async {
                          self?.delegate?.didUpdateISO(clampedISO)
                          self?.logger.debug("Successfully set ISO to \(clampedISO)")
                     }
                }
            } else {
                 logger.warning("Custom exposure mode not supported.")
            }
            
            device.unlockForConfiguration()
            
            // Delegate call moved inside completion handler
            // delegate?.didUpdateISO(clampedISO)
            // logger.debug("Successfully set ISO to \(clampedISO)")
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
                device.setExposureModeCustom(duration: speed, iso: safeISO) { [weak self] timestamp in
                    // Report the value back via delegate *after* it's set
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.delegate?.didUpdateShutterSpeed(speed)
                        // If we had to correct ISO, update that too
                        if safeISO != currentISO {
                            self.delegate?.didUpdateISO(safeISO)
                        }
                        self.logger.debug("Successfully set shutter speed to \(CMTimeGetSeconds(speed))s")
                    }
                }
            } else {
                 logger.warning("Custom exposure mode not supported.")
            }
            
            device.unlockForConfiguration()
            
            // Delegate calls moved inside completion handler
            // delegate?.didUpdateShutterSpeed(speed)
            // If we had to correct ISO, update that too
            // if safeISO != currentISO {
            //     delegate?.didUpdateISO(safeISO)
            // }
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
        // Only update if the state actually changes
        guard isAutoExposureEnabled != enabled else { return }
        
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
                    // Report current values when switching back to auto
                    reportCurrentDeviceValues()
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
                                                 iso: clampedISO) { [weak self] _ in
                         // Report the value back via delegate *after* it's set
                         DispatchQueue.main.async {
                              self?.delegate?.didUpdateISO(clampedISO)
                              self?.logger.debug("Successfully set ISO to \(clampedISO)")
                         }
                    }
                    self.logger.info("Manual exposure enabled with ISO \(clampedISO)")
                    
                    // If we had to adjust the ISO, update the delegate
                    if clampedISO != currentISO {
                        self.delegate?.didUpdateISO(clampedISO)
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
            logger.error("[ExposureLock] Cannot set exposure lock: No camera device available")
            delegate?.didEncounterError(.configurationFailed(message: "No camera device for exposure lock"))
            return
        }
        
        let deviceName = device.localizedName
        logger.info("[ExposureLock] Request to set lock=\(locked) for device: \(deviceName)")

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
        
        logger.debug("[ExposureLock] Determined target exposure mode: \(String(describing: targetMode))")
        
        // Check if the target mode is supported
        let isSupported = device.isExposureModeSupported(targetMode)
        logger.info("[ExposureLock] Device \(deviceName) supports mode \(String(describing: targetMode)): \(isSupported)")
        guard isSupported else {
            logger.warning("[ExposureLock] Exposure mode \(String(describing: targetMode)) is not supported by \(deviceName). Cannot set.")
            // Optionally, inform the delegate or handle this case appropriately.
            // For now, we just log and return, leaving the mode unchanged.
            return
        }
        
        // Only apply if the mode needs to change
        if device.exposureMode != targetMode {
            logger.debug("[ExposureLock] Current mode (\(device.exposureMode.rawValue)) differs from target (\(targetMode.rawValue)). Attempting change on \(deviceName)...")
            do {
                logger.debug("[ExposureLock] Attempting lockForConfiguration on \(deviceName)...)")
                try device.lockForConfiguration()
                logger.debug("[ExposureLock] lockForConfiguration succeeded. Setting exposureMode to \(targetMode.rawValue) on \(deviceName)...")
                device.exposureMode = targetMode
                logger.debug("[ExposureLock] Setting exposureMode completed. Unlocking configuration on \(deviceName)...")
                device.unlockForConfiguration()
                logger.info("[ExposureLock] Successfully set exposure mode to \(String(describing: targetMode)) for \(deviceName)")

                // Report current values ONLY if we locked or unlocked to AUTO.
                // If we unlocked to CUSTOM, rely solely on KVO updates to avoid reporting a potentially stale value immediately after mode switch.
                if targetMode == .locked || targetMode == .continuousAutoExposure {
                    reportCurrentDeviceValues()
                }

            } catch {
                logger.error("[ExposureLock] Error setting exposure mode to \(String(describing: targetMode)) for \(deviceName): \(error.localizedDescription)")
                delegate?.didEncounterError(.configurationFailed(message: "Failed to set exposure mode for \(deviceName): \(error.localizedDescription)"))
                // Attempt to unlock configuration if lock failed during change
                device.unlockForConfiguration()
            }
        } else {
            logger.info("[ExposureLock] Exposure mode on \(deviceName) is already \(String(describing: targetMode)), no change needed.")
            // Even if no mode change occurred, report values if the target was lock or auto, 
            // as the interpretation might change (e.g., KVO reporting might differ).
            // Avoid reporting if target was .custom and already .custom to prevent potential stale values.
            if targetMode == .locked || targetMode == .continuousAutoExposure {
                reportCurrentDeviceValues()
            }
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
    
    /// Directly queries the current device white balance temperature.
    /// Returns the temperature in Kelvin, or nil if device is unavailable or mode doesn't support it.
    func getCurrentWhiteBalanceTemperature() -> Float? {
        guard let device = device else { 
            logger.error("Cannot get current WB temperature: No device")
            return nil 
        }
        
        // WB temperature is typically relevant in auto or locked modes
        guard device.whiteBalanceMode == .continuousAutoWhiteBalance || device.whiteBalanceMode == .locked else {
            // logger.debug("Cannot get current WB temperature: WB mode is not auto or locked (\(device.whiteBalanceMode.rawValue))")
            // Return nil or perhaps a default? Returning nil seems clearer.
            return nil
        }
        
        // Ensure gains are valid before converting
        let gains = device.deviceWhiteBalanceGains
        guard gains.redGain > 0, gains.greenGain > 0, gains.blueGain > 0 else {
            logger.warning("Cannot get current WB temperature: Invalid device gains (\(String(describing: gains))")
            return nil
        }

        let tempAndTint = device.temperatureAndTintValues(for: gains)
        // logger.debug("Queried current WB temp: \(tempAndTint.temperature)K")
        return tempAndTint.temperature
    }
} 