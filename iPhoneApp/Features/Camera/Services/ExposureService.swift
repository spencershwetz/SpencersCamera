import AVFoundation
import os.log
import CoreMedia

protocol ExposureServiceDelegate: AnyObject {
    func didUpdateWhiteBalance(_ temperature: Float, tint: Float)
    func didUpdateISO(_ iso: Float)
    func didUpdateShutterSpeed(_ speed: CMTime)
    func didEncounterError(_ error: CameraError)
    func didUpdateExposureTargetBias(_ bias: Float)
}

// Add at the top after imports
enum ExposureServiceError: Error {
    case deviceUnavailable
    case invalidState
    case transitionFailed
    case lockFailed
    
    var userMessage: String {
        switch self {
        case .deviceUnavailable: return "Camera device unavailable"
        case .invalidState: return "Invalid camera state"
        case .transitionFailed: return "Failed to change exposure settings"
        case .lockFailed: return "Failed to lock exposure"
        }
    }
}

// Inherit from NSObject to support KVO
class ExposureService: NSObject {
    /// Optional closure to query if video stabilization is currently enabled.
    var isVideoStabilizationCurrentlyEnabled: (() -> Bool)? = nil
    private let logger = Logger(subsystem: "com.camera", category: "ExposureService")
    private weak var delegate: ExposureServiceDelegate?
    
    private var device: AVCaptureDevice?
    private var isAutoExposureEnabled = true
    
    // --- Shutter Priority State ---
    private var isShutterPriorityActive: Bool {
        get { stateQueue.sync { _isShutterPriorityActive } }
        set { stateQueue.sync { _isShutterPriorityActive = newValue } }
    }
    private var targetShutterDuration: CMTime?
    private var exposureTargetOffsetObservation: NSKeyValueObservation?
    private var lastIsoAdjustmentTime: Date = .distantPast // For rate limiting

    // --- Tuning Parameters (Adjust as needed) ---
    private let isoAdjustmentInterval: TimeInterval = 0.1 // Max 10 ISO adjustments/sec
    private let isoPercentageThreshold: Float = 0.05 // 5% change needed to trigger adjustment
    private let evOffsetThreshold: Float = 0.1 // 0.1 EV offset needed to trigger adjustment

    // --- Dispatch Queue ---
    // Add a dedicated serial queue for exposure adjustments to avoid blocking KVO/session queues
    private let exposureAdjustmentQueue = DispatchQueue(label: "com.camera.exposureAdjustmentQueue", qos: .userInitiated)
    // --- Recording Lock State ---
    private var isTemporarilyLockedForRecording: Bool = false

    // KVO Observation tokens
    private var isoObservation: NSKeyValueObservation?
    private var exposureDurationObservation: NSKeyValueObservation?
    private var whiteBalanceGainsObservation: NSKeyValueObservation?
    // Observation for exposure target bias
    private var exposureBiasObservation: NSKeyValueObservation?
    
    // Add new properties
    private let stateQueue = DispatchQueue(label: "com.camera.exposureState", qos: .userInitiated)
    private var _isShutterPriorityActive: Bool = false
    private var lastKnownGoodState: ExposureState?
    
    init(delegate: ExposureServiceDelegate) {
        self.delegate = delegate
    }
    
    // Clean up observers on deinitialization
    deinit {
        removeDeviceObservers()
        logger.info("ExposureService deinitialized, observers removed.")
    }
    
    func setDevice(_ device: AVCaptureDevice?) {
        // ADD GUARD: Check if the new device is the same as the current one
        guard device != self.device else {
            logger.debug("ExposureService setDevice called with the same device (\(device?.localizedName ?? "nil")), skipping observer setup.")
            // Ensure observers are still attached if the device is not nil
            if self.device != nil && isoObservation == nil { // Check if observers might be missing
                logger.warning("Device is the same, but observers seem missing. Re-attaching for \(self.device!.localizedName).")
                removeDeviceObservers() // Clean up just in case
                setupDeviceObservers(for: self.device!)
            } else if self.device == nil {
                logger.debug("Current device is nil, no observers to ensure.")
            }
            return
        }
        
        logger.info("ExposureService setDevice called with NEW device: \(device?.localizedName ?? "nil")")
        removeDeviceObservers() // Remove observers for the OLD device
        self.device = device // Set the NEW device
        if let newDevice = device {
            logger.info("ExposureService setupDeviceObservers called for NEW device: \(newDevice.localizedName)")
            setupDeviceObservers(for: newDevice) // Setup observers for the NEW device
            self.isAutoExposureEnabled = (newDevice.exposureMode == .continuousAutoExposure)
            logger.info("Initial auto exposure state set to: \(self.isAutoExposureEnabled) for new device")
        } else {
             logger.info("ExposureService setDevice called with nil, observers removed, device set to nil.")
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
            // Log the KVO update regardless of mode for debugging SP
            // self.logger.debug("[KVO ISO] Observed ISO change to: \(newISO) (Current Mode: \(device.exposureMode.rawValue))" ) // REMOVED
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
            // Use the dedicated handler function
            self?.handleWhiteBalanceGainsChange(device, change: change)
        }
        
        // Observe exposure target offset for Shutter Priority
        exposureTargetOffsetObservation = device.observe(\.exposureTargetOffset, options: [.new]) { [weak self] device, change in
            // No need to check mode here, handleExposureTargetOffsetUpdate checks isShutterPriorityActive
            self?.handleExposureTargetOffsetUpdate(change: change)
        }
        
        // Observe exposure target bias changes
        exposureBiasObservation = device.observe(\.exposureTargetBias, options: [.new]) { [weak self] device, change in
            guard let self = self, let newBias = change.newValue else { return }
            DispatchQueue.main.async {
                self.delegate?.didUpdateExposureTargetBias(newBias)
            }
        }
        
        // Report initial values immediately after setting observers
        reportCurrentDeviceValues()
    }
    
    // Remove KVO observers
    // Make internal so CameraViewModel's deinit can call it
    func removeDeviceObservers() {
        logger.info("Removing KVO observers. Stack trace: \(Thread.callStackSymbols.joined(separator: "\\n"))")
        isoObservation?.invalidate()
        exposureDurationObservation?.invalidate()
        whiteBalanceGainsObservation?.invalidate()
        exposureTargetOffsetObservation?.invalidate()
        exposureBiasObservation?.invalidate()
        isoObservation = nil
        exposureDurationObservation = nil
        whiteBalanceGainsObservation = nil
        exposureTargetOffsetObservation = nil
        exposureBiasObservation = nil
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
             // Report White Balance (Using Safe Helper)
             if device.whiteBalanceMode == .continuousAutoWhiteBalance || device.whiteBalanceMode == .locked {
                 // Use the safe helper function
                 if let tempAndTint = self.safeGetTemperatureAndTint(for: device.deviceWhiteBalanceGains) {
                     self.delegate?.didUpdateWhiteBalance(tempAndTint.temperature, tint: tempAndTint.tint) // Pass tint here too
                     logger.debug("Reporting current WB Temp: \(tempAndTint.temperature), Tint: \(tempAndTint.tint)")
                 } else {
                     logger.warning("Could not report initial white balance - conversion failed or gains invalid.")
                 }
             }
             // Report exposure bias
             self.delegate?.didUpdateExposureTargetBias(device.exposureTargetBias)
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
                    // Also need to read the tint value after setting
                    let currentTempAndTint = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                    DispatchQueue.main.async {
                        self?.delegate?.didUpdateWhiteBalance(currentTempAndTint.temperature, tint: currentTempAndTint.tint) // Pass both
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
        // If Shutter Priority is active, do not allow manual shutter speed changes.
        guard !isShutterPriorityActive else {
            logger.info("updateShutterSpeed called while Shutter Priority is active. Ignoring.")
            return
        }

        guard let device = device else {
            logger.error("No camera device available for shutter speed update")
            return
        }

        do {
            try device.lockForConfiguration()

            // Clamp the requested speed to the device's limits
            let minDuration = device.activeFormat.minExposureDuration
            let maxDuration = device.activeFormat.maxExposureDuration
            let clampedSpeed = CMTimeClampToRange(speed, range: CMTimeRange(start: minDuration, duration: maxDuration - minDuration))

            if CMTimeCompare(clampedSpeed, speed) != 0 {
                 logger.debug("Clamped shutter speed from \(CMTimeGetSeconds(speed))s to \(CMTimeGetSeconds(clampedSpeed))s")
            }

            // Set exposure mode to custom and use the clamped speed
            if device.isExposureModeSupported(.custom) {
                // Revert to using setExposureModeCustom with currentISO
                device.exposureMode = .custom
                device.setExposureModeCustom(duration: clampedSpeed, iso: AVCaptureDevice.currentISO) { [weak self] timestamp in
                    // Report the actually set clamped speed immediately.
                    // KVO should handle reporting the automatically adjusted ISO.
                    DispatchQueue.main.async {
                        self?.delegate?.didUpdateShutterSpeed(clampedSpeed)
                        self?.logger.debug("Set shutter speed to \\(CMTimeGetSeconds(clampedSpeed))s via setExposureModeCustom (ISO should adjust automatically)")
                    }
                }
            } else {
                 logger.warning("Custom exposure mode not supported.")
            }

            device.unlockForConfiguration()

        } catch {
            logger.error("Shutter speed update error: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed)
        }
    }
    
    func updateShutterAngle(_ angle: Double, frameRate: Double) {
        // If Shutter Priority is active, do not allow manual shutter angle changes.
        guard !isShutterPriorityActive else {
            logger.info("updateShutterAngle called while Shutter Priority is active. Ignoring.")
            return
        }

        guard frameRate > 0 else {
             logger.error("Invalid frame rate (\(frameRate)) for shutter angle calculation.")
             delegate?.didEncounterError(.configurationFailed(message: "Invalid frame rate for shutter angle"))
             return
        }
        
        // Clamp angle (e.g., 1.1 to 360 degrees) - adjust as needed
        let clampedAngle = min(max(angle, 1.1), 360.0)
        if clampedAngle != angle {
            logger.debug("Clamped shutter angle from \(angle)° to \(clampedAngle)°")
        }
        
        let durationSeconds = (clampedAngle / 360.0) * (1.0 / frameRate)
        let time = CMTimeMakeWithSeconds(durationSeconds, preferredTimescale: 1_000_000) // Higher precision timescale

        logger.debug("Calculated shutter duration \(durationSeconds)s for angle \(clampedAngle)° at \(frameRate)fps")

        // Reuse the updated updateShutterSpeed logic
        updateShutterSpeed(time)
    }
    
    /// Sets the exposure mode to custom with a specific duration and ISO.
    /// This is used for locking exposure in Shutter Priority + Record Lock mode.
    func setCustomExposure(duration: CMTime, iso: Float) {
        guard let device = device else {
            logger.error("No camera device available for custom exposure setting")
            return
        }
        
        do {
            try device.lockForConfiguration()
            
            // Clamp duration and ISO to device limits
            let minDuration = device.activeFormat.minExposureDuration
            let maxDuration = device.activeFormat.maxExposureDuration
            let clampedDuration = CMTimeClampToRange(duration, range: CMTimeRange(start: minDuration, duration: maxDuration - minDuration))

            let minISO = device.activeFormat.minISO
            let maxISO = device.activeFormat.maxISO
            let clampedISO = min(max(minISO, iso), maxISO)
            
            if device.isExposureModeSupported(.custom) {
                device.exposureMode = .custom
                device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO) { [weak self] timestamp in
                    // Log success but DO NOT call delegates here. Rely on KVO for state updates.
                    // This prevents race conditions where this completion handler overwrites
                    // newer KVO updates after recording stops / modes change.
                    // DispatchQueue.main.async {
                    //     guard let self = self else { return }
                    //     // Report the actually set values
                    //     self.delegate?.didUpdateShutterSpeed(clampedDuration)
                    //     self.delegate?.didUpdateISO(clampedISO)
                    // }
                     self?.logger.info("[setCustomExposure Completion] Successfully set custom exposure: Duration \\(CMTimeGetSeconds(clampedDuration))s, ISO \\(clampedISO)")
                }
            } else {
                 logger.warning("Custom exposure mode not supported.")
            }

            device.unlockForConfiguration()

        } catch {
            logger.error("Custom exposure setting error: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed)
        }
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
    
    // Helper to clamp temperature and tint to safe ranges
    private func clampedTemperature(_ temp: Float) -> Float {
        return min(max(temp, 2500.0), 8000.0)
    }
    private func clampedTint(_ tint: Float) -> Float {
        return min(max(tint, -150.0), 150.0)
    }

    func updateTint(_ tint: Float, currentWhiteBalance: Float) {
        guard let device = device else { 
            logger.error("No camera device available")
            return 
        }
        
        do {
            try device.lockForConfiguration()
            
            // Clamp temperature and tint to safe ranges
            let clampedTemperature = clampedTemperature(currentWhiteBalance)
            let clampedTint = clampedTint(tint)
            if clampedTemperature != currentWhiteBalance || clampedTint != tint {
                logger.warning("Clamped WB values: temperature=\(currentWhiteBalance)→\(clampedTemperature), tint=\(tint)→\(clampedTint)")
            }
            let tnt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: clampedTemperature, tint: clampedTint)
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
                    // Need to read the actual temp/tint after setting gains
                    let currentTempAndTint = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                    DispatchQueue.main.async {
                        self?.delegate?.didUpdateWhiteBalance(currentTempAndTint.temperature, tint: currentTempAndTint.tint)
                    }
                }
            } else {
                 logger.warning("Locked white balance mode not supported.")
            }
            device.unlockForConfiguration()
        } catch {
            logger.error("Tint adjustment error: \(error.localizedDescription)")
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

    // --- Shutter Priority Methods ---
    /// Enables Shutter Priority mode with a fixed duration and optionally an initial ISO.
    /// - Parameters:
    ///   - duration: The shutter duration to use (typically 180°).
    ///   - initialISO: Optional ISO value to set immediately (used after lens switch).
    func enableShutterPriority(duration: CMTime, initialISO: Float? = nil) {
        guard let device = device else {
            logger.error("SP Enable: No device available.")
            return
        }
        // Clamp the requested duration just in case
        let minDuration = device.activeFormat.minExposureDuration
        let maxDuration = device.activeFormat.maxExposureDuration
        let clampedDuration = CMTimeClampToRange(duration, range: CMTimeRange(start: minDuration, duration: maxDuration - minDuration))
        self.targetShutterDuration = clampedDuration
        self.isShutterPriorityActive = true
        self.isTemporarilyLockedForRecording = false // Ensure recording lock is off when enabling/re-enabling
        self.logger.info("Enabling Shutter Priority: Duration \(String(format: "%.5f", clampedDuration.seconds))s")
        // Perform initial mode set on the adjustment queue
        exposureAdjustmentQueue.async { [weak self] in
            guard let self = self, let currentDevice = self.device, self.isShutterPriorityActive else { return } // Re-check state
            let minISO = currentDevice.activeFormat.minISO
            let maxISO = currentDevice.activeFormat.maxISO
            let isoToSet: Float
            if let initialISO = initialISO {
                isoToSet = min(max(initialISO, minISO), maxISO)
            } else {
                isoToSet = min(max(currentDevice.iso, minISO), maxISO)
            }
            do {
                try currentDevice.lockForConfiguration()
                // Set the mode to custom with the fixed duration and ISO
                currentDevice.setExposureModeCustom(duration: clampedDuration, iso: isoToSet) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.delegate?.didUpdateShutterSpeed(clampedDuration)
                        self?.delegate?.didUpdateISO(isoToSet)
                        self?.logger.info("SP Enabled: Initial ISO set to \(String(format: "%.1f", isoToSet))")
                    }
                }
                currentDevice.unlockForConfiguration()
            } catch {
                self.logger.error("SP Enable: Error setting initial custom exposure: \(error.localizedDescription)")
                currentDevice.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.isShutterPriorityActive = false
                    self.targetShutterDuration = nil
                    self.delegate?.didEncounterError(.configurationFailed(message: "Failed to enable SP"))
                }
            }
        }
    }
    
    func disableShutterPriority() {
        guard isShutterPriorityActive else {
            // logger.debug("SP Disable: Already inactive.")
            return
        }
        guard let _ = device else {
            logger.error("SP Disable: No device available.")
            return
        }

        isShutterPriorityActive = false // Set flag immediately to stop adjustments
        targetShutterDuration = nil
        isTemporarilyLockedForRecording = false // Ensure recording lock is off when disabling
        logger.info("Disabling Shutter Priority.")

        // Revert to auto-exposure on the adjustment queue
        exposureAdjustmentQueue.async { [weak self] in
             guard let self = self, let currentDevice = self.device else { return }

            do {
                try currentDevice.lockForConfiguration()
                // Always revert to continuousAutoExposure when SP is turned off
                if currentDevice.isExposureModeSupported(.continuousAutoExposure) {
                    currentDevice.exposureMode = .continuousAutoExposure
                     self.logger.info("SP Disabled: Reverted to Continuous Auto Exposure.")
                    // KVO should automatically report the new auto values
                } else {
                    self.logger.warning("SP Disable: Continuous Auto Exposure not supported, leaving mode as is.")
                }
                currentDevice.unlockForConfiguration()
            } catch {
                self.logger.error("SP Disable: Error reverting to auto exposure: \(error.localizedDescription)")
                 // Attempt to unlock configuration if lock failed during change
                 currentDevice.unlockForConfiguration()
                 // Should we notify delegate of error?
            }
        }
    }
    // --------------------------------

    // --- Add new method here ---
    private func handleExposureTargetOffsetUpdate(change: NSKeyValueObservedChange<Float>) {
        // Ensure SP is active and we have the necessary info
        guard isShutterPriorityActive,
              let targetDuration = targetShutterDuration,
              let newOffset = change.newValue else {
            // logger.debug("SP Adjust: KVO ignored (SP inactive or missing data)")
            return
        }
        
        // --- Add Check for Recording Lock ---
        guard !isTemporarilyLockedForRecording else {
            logger.debug("SP Adjust: Ignored (Temporarily locked for recording)")
            return
        }
        // --- End Check ---

        // Throttle adjustments
        let now = Date()
        guard now.timeIntervalSince(lastIsoAdjustmentTime) > isoAdjustmentInterval else {
             // logger.debug("SP Adjust: KVO ignored (Rate limited)")
            return
        }

        // Only adjust if EV offset is significant
        guard abs(newOffset) > evOffsetThreshold else {
            // logger.debug("SP Adjust: KVO ignored (EV offset \(newOffset) within threshold \(evOffsetThreshold))")
            return
        }

        // Perform calculations and device interaction on the dedicated queue
        exposureAdjustmentQueue.async { [weak self] in
             guard let self = self, self.isShutterPriorityActive, let currentDevice = self.device else { return } // Re-check state inside async block

            let currentISO = currentDevice.iso
            let minISO = currentDevice.activeFormat.minISO
            let maxISO = currentDevice.activeFormat.maxISO

            // Calculate the ideal ISO to compensate for the offset
            // newISO = currentISO / 2^(offset)
            var idealISO = currentISO / pow(2.0, newOffset)

            // Clamp ISO to device limits
            idealISO = min(max(idealISO, minISO), maxISO)

            // Only adjust if the change is significant enough
            let percentageChange = abs(idealISO - currentISO) / currentISO
            guard percentageChange > self.isoPercentageThreshold else {
                // self.logger.debug("SP Adjust: KVO ignored (ISO change \(percentageChange * 100)% within threshold \(self.isoPercentageThreshold * 100)%)")
                return
            }

            self.logger.debug("SP Adjust: Offset \(String(format: "%.2f", newOffset))EV, Current ISO \(String(format: "%.1f", currentISO)), Ideal ISO \(String(format: "%.1f", idealISO))")

            do {
                try currentDevice.lockForConfiguration()
                // Re-apply custom exposure with the fixed duration and newly calculated ISO
                currentDevice.setExposureModeCustom(duration: targetDuration, iso: idealISO) { [weak self] _ in
                    // Note: KVO for 'iso' should fire and update the delegate/UI separately
                    self?.logger.debug("SP Adjustment Applied: ISO set attempt to \(String(format: "%.1f", idealISO))")
                }
                self.lastIsoAdjustmentTime = now // Update timestamp only if adjustment was attempted
                currentDevice.unlockForConfiguration()
            } catch {
                self.logger.error("SP Adjust: Error setting custom exposure: \(error.localizedDescription)")
                // Attempt to unlock configuration if lock failed during change
                currentDevice.unlockForConfiguration()
            }
        }
    }
    // --------------------------

    // MARK: - Shutter Priority Recording Lock
    
    /// Locks exposure for recording when Shutter Priority is active
    func lockShutterPriorityExposureForRecording() {
        guard let device = device else {
            logger.error("No camera device available for SP recording lock")
            return
        }
        
        do {
            try device.lockForConfiguration()
            
            // Store current values before locking
            let currentISO = device.iso
            let currentDuration = device.exposureDuration
            
            // Set to locked mode with current values
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
                logger.info("🔒 Locked SP exposure for recording with ISO: \(currentISO), Duration: \(CMTimeGetSeconds(currentDuration))s")
            }
            
            device.unlockForConfiguration()
            
            // Set internal state
            isTemporarilyLockedForRecording = true
            
        } catch {
            logger.error("Failed to lock SP exposure for recording: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed)
        }
    }
    
    /// Unlocks exposure after recording when Shutter Priority is active
    func unlockShutterPriorityExposureAfterRecording() {
        guard let device = device else {
            logger.error("No camera device available for SP recording unlock")
            return
        }
        
        do {
            try device.lockForConfiguration()
            
            // Return to custom mode for Shutter Priority
            if device.isExposureModeSupported(.custom) {
                device.exposureMode = .custom
                // Re-apply the target shutter duration if we have it
                if let targetDuration = targetShutterDuration {
                    device.setExposureModeCustom(duration: targetDuration, iso: device.iso)
                }
                logger.info("🔓 Unlocked SP exposure after recording, returning to custom mode")
            }
            
            device.unlockForConfiguration()
            
            // Reset internal state
            isTemporarilyLockedForRecording = false
            
        } catch {
            logger.error("Failed to unlock SP exposure after recording: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed)
        }
    }
    
    // MARK: - Safe White Balance Conversion (NEW HELPER)

    private func safeGetTemperatureAndTint(for gains: AVCaptureDevice.WhiteBalanceGains) -> AVCaptureDevice.WhiteBalanceTemperatureAndTintValues? {
        guard let device = device else { return nil }
        
        // Clamp gains to valid range
        let maxGain = device.maxWhiteBalanceGain
        let clampedGains = AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(1.0, gains.redGain), maxGain),
            greenGain: min(max(1.0, gains.greenGain), maxGain),
            blueGain: min(max(1.0, gains.blueGain), maxGain)
        )
        
        return device.temperatureAndTintValues(for: clampedGains)
    }

    // MARK: - KVO Handlers (Adjusted)

    // Observe white balance gains changes
    private func handleWhiteBalanceGainsChange(_: AVCaptureDevice, change: NSKeyValueObservedChange<AVCaptureDevice.WhiteBalanceGains>) {
        guard let device = device,
              let newGains = change.newValue,
              device.whiteBalanceMode == .continuousAutoWhiteBalance || device.whiteBalanceMode == .locked else { return }
        
        // Use the safe helper function that clamps gains
        if let tempAndTint = safeGetTemperatureAndTint(for: newGains) {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didUpdateWhiteBalance(tempAndTint.temperature, tint: tempAndTint.tint)
            }
        }
    }

    // MARK: - Exposure Compensation / Bias

    /// Updates the exposure target bias (compensation) on the current device.
    /// - Parameter bias: The desired exposure bias value. Will be clamped to the device supported range.
    func updateExposureTargetBias(_ bias: Float) {
        guard let device = device else {
            logger.error("[ExposureBias] No camera device available to set exposure bias")
            return
        }

        let clampedBias = min(max(device.minExposureTargetBias, bias), device.maxExposureTargetBias)

        // Only log on larger threshold changes to avoid rate limit warnings
        if abs(bias - device.exposureTargetBias) > 0.5 {
            logger.debug("[ExposureBias] EV bias: \(String(format: "%.1f", clampedBias))")
        }

        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(clampedBias) { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.delegate?.didUpdateExposureTargetBias(clampedBias)
                }
            }
            device.unlockForConfiguration()
        } catch {
            logger.error("[ExposureBias] Failed to set exposure bias: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed(message: "Failed to set exposure bias: \(error.localizedDescription)"))
        }
    }

    // Add new methods before MARK: - Shutter Priority Recording Lock
    private func recoverFromFailedExposureOperation() {
        exposureAdjustmentQueue.async { [weak self] in
            guard let self = self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                // Attempt to restore last known good state
                if self.isShutterPriorityActive {
                    self.enableShutterPriority(duration: self.targetShutterDuration ?? device.exposureDuration)
                } else {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                self.logger.error("Recovery failed: \(error.localizedDescription)")
            }
        }
    }

    func prepareForLensSwitch() {
        guard let device = device else { return }
        lastKnownGoodState = ExposureState.capture(from: device)
    }

    func restoreAfterLensSwitch() {
        guard let state = lastKnownGoodState,
              let device = device else { return }
        
        exposureAdjustmentQueue.async {
            do {
                try device.lockForConfiguration()
                if state.isShutterPriority {
                    self.enableShutterPriority(duration: state.duration, initialISO: state.iso)
                } else if state.isLocked {
                    device.setExposureModeCustom(duration: state.duration, iso: state.iso)
                }
                device.unlockForConfiguration()
            } catch {
                self.logger.error("Restore after lens switch failed: \(error)")
            }
        }
    }

    private func smoothTransitionToNewExposure(targetISO: Float, duration: CMTime) {
        guard let device = device else { return }
        
        let steps = 5
        let currentISO = device.iso
        let isoStep = (targetISO - currentISO) / Float(steps)
        
        for i in 1...steps {
            let intermediateISO = currentISO + (isoStep * Float(i))
            exposureAdjustmentQueue.asyncAfter(deadline: .now() + 0.05 * Double(i)) {
                try? device.lockForConfiguration()
                device.setExposureModeCustom(duration: duration, iso: intermediateISO)
                device.unlockForConfiguration()
            }
        }
    }

    private func monitorExposureStability() {
        var samples = [Float]()
        let stabilityTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self,
                  let device = self.device,
                  self.isShutterPriorityActive else { return }
            
            samples.append(device.iso)
            if samples.count > 10 {
                samples.removeFirst()
                let variance = self.calculateVariance(samples)
                if variance > 100 {
                    self.logger.warning("High ISO variance detected: \(variance)")
                }
            }
        }
        stabilityTimer.tolerance = 0.01
    }

    private func calculateVariance(_ samples: [Float]) -> Float {
        let mean = samples.reduce(0, +) / Float(samples.count)
        let sumSquaredDiff = samples.reduce(0) { $0 + pow($1 - mean, 2) }
        return sumSquaredDiff / Float(samples.count)
    }

    // MARK: - White Balance Auto Mode Handling
    /// Enables or disables automatic white balance. When `enabled` is true the device white balance mode is set to
    /// `.continuousAutoWhiteBalance` (if supported). When false, the mode is switched to `.locked` so that subsequent
    /// manual temperature updates via `updateWhiteBalance(_:)` take effect.
    /// The delegate is notified of the current temperature & tint after the change so that the UI stays in sync.
    func setAutoWhiteBalanceEnabled(_ enabled: Bool) {
        guard let device = device else {
            logger.error("No camera device available – cannot change white-balance mode.")
            return
        }

        do {
            try device.lockForConfiguration()
            if enabled {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                    logger.info("Set white-balance mode to continuousAutoWhiteBalance")
                } else {
                    logger.warning("continuousAutoWhiteBalance not supported on current device")
                }
            } else {
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                    logger.info("Set white-balance mode to locked for manual adjustment")
                }
            }
            device.unlockForConfiguration()

            // Notify delegate of the current WB state so UI can update immediately.
            let currentTempAndTint = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didUpdateWhiteBalance(currentTempAndTint.temperature, tint: currentTempAndTint.tint)
            }
        } catch {
            logger.error("Failed to change white-balance mode: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed)
        }
    }
}

// Add after class ExposureService: NSObject {
private struct ExposureState {
    let iso: Float
    let duration: CMTime
    let isLocked: Bool
    let isShutterPriority: Bool
    
    static func capture(from device: AVCaptureDevice) -> ExposureState {
        return ExposureState(
            iso: device.iso,
            duration: device.exposureDuration,
            isLocked: device.exposureMode == .locked,
            isShutterPriority: device.exposureMode == .custom
        )
    }
} 