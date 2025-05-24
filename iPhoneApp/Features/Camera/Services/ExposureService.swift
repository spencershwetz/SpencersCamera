import AVFoundation
import os.log
import CoreMedia
import Combine

protocol ExposureServiceDelegate: AnyObject {
    func didUpdateWhiteBalance(_ temperature: Float, tint: Float)
    func didUpdateISO(_ iso: Float)
    func didUpdateShutterSpeed(_ speed: CMTime)
    func didEncounterError(_ error: CameraError)
    func didUpdateExposureTargetBias(_ bias: Float)
}

// MARK: - Performance Optimization Data Structures

/// Represents a single exposure update type
enum ExposureUpdate {
    case iso(Float)
    case shutterSpeed(CMTime)
    case whiteBalance(temperature: Float, tint: Float)
    case exposureBias(Float)
}

/// Batches multiple exposure updates to reduce UI thrashing
struct ExposureUpdateBatch {
    var iso: Float?
    var shutterSpeed: CMTime?
    var whiteBalance: (temperature: Float, tint: Float)?
    var exposureBias: Float?
    
    mutating func add(_ update: ExposureUpdate) {
        switch update {
        case .iso(let value):
            iso = value
        case .shutterSpeed(let value):
            shutterSpeed = value
        case .whiteBalance(let temperature, let tint):
            whiteBalance = (temperature, tint)
        case .exposureBias(let value):
            exposureBias = value
        }
    }
    
    mutating func clear() {
        iso = nil
        shutterSpeed = nil
        whiteBalance = nil
        exposureBias = nil
    }
    
    var isEmpty: Bool {
        return iso == nil && shutterSpeed == nil && whiteBalance == nil && exposureBias == nil
    }
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
    
    // State machine for exposure management
    private let stateMachine = ExposureStateMachine()
    
    // --- Shutter Priority State ---
    private var targetShutterDuration: CMTime?
    private var exposureTargetOffsetObservation: NSKeyValueObservation?
    // Intelligent debouncing for shutter priority adjustments
    private var shutterPriorityDebouncer: AnyCancellable?
    private let shutterPrioritySubject = PassthroughSubject<Float, Never>()

    // --- Tuning Parameters (Optimized for performance) ---
    private let isoPercentageThreshold: Float = 0.05 // 5% change needed to trigger adjustment
    private let evOffsetThreshold: Float = 0.1 // 0.1 EV offset needed to trigger adjustment
    
    // --- Debouncing and Batching ---
    private var updateDebouncer: AnyCancellable?
    private let updateSubject = PassthroughSubject<ExposureUpdate, Never>()
    private var pendingUpdates = ExposureUpdateBatch()
    private let batchLock = NSLock()

    // --- Dispatch Queue ---
    // Add a dedicated serial queue for exposure adjustments to avoid blocking KVO/session queues
    private let exposureAdjustmentQueue = DispatchQueue(label: "com.camera.exposureAdjustmentQueue", qos: .userInitiated)

    // KVO Observation tokens
    private var isoObservation: NSKeyValueObservation?
    private var exposureDurationObservation: NSKeyValueObservation?
    private var whiteBalanceGainsObservation: NSKeyValueObservation?
    // Observation for exposure target bias
    private var exposureBiasObservation: NSKeyValueObservation?
    
    // Add new properties
    private let stateQueue = DispatchQueue(label: "com.camera.exposureState", qos: .userInitiated)
    private var lastKnownGoodState: ExposureState?
    private var cancellables = Set<AnyCancellable>()
    
    // Computed property to get current exposure mode
    var currentExposureMode: ExposureMode {
        switch stateMachine.currentState {
        case .auto:
            return .auto
        case .manual:
            return .manual
        case .shutterPriority:
            return .shutterPriority
        case .locked, .recordingLocked:
            return .locked
        }
    }
    
    init(delegate: ExposureServiceDelegate) {
        self.delegate = delegate
        super.init()
        
        // Setup state machine callbacks
        stateMachine.onStateChange = { [weak self] oldState, newState in
            self?.handleStateTransition(from: oldState, to: newState)
        }
        
        setupUpdateBatching()
    }
    
    // Handle state transitions
    private func handleStateTransition(from oldState: ExposureState, to newState: ExposureState) {
        guard let device = device else { return }
        
        logger.info("Handling exposure state transition: \(String(describing: oldState)) -> \(String(describing: newState))")
        
        // Apply the new state to the device
        exposureAdjustmentQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                try device.lockForConfiguration()
                
                switch newState {
                case .auto:
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    
                case .manual(let iso, let duration):
                    if device.isExposureModeSupported(.custom) {
                        device.exposureMode = .custom
                        // Clamp ISO to device limits before setting
                        let minISO = device.activeFormat.minISO
                        let maxISO = device.activeFormat.maxISO
                        let clampedISO = min(max(iso, minISO), maxISO)
                        
                        if clampedISO != iso {
                            self.logger.warning("Clamped ISO from \(iso) to \(clampedISO) to stay within device limits [\(minISO), \(maxISO)]")
                        }
                        
                        device.setExposureModeCustom(duration: duration, iso: clampedISO) { _ in
                            // Queue batched updates instead of immediate dispatch
                            self.queueUpdate(.iso(clampedISO))
                            self.queueUpdate(.shutterSpeed(duration))
                        }
                    }
                    
                case .shutterPriority(let targetDuration, let manualISO):
                    self.targetShutterDuration = targetDuration
                    if device.isExposureModeSupported(.custom) {
                        device.exposureMode = .custom
                        if let manualISO = manualISO {
                            // Manual ISO override is set
                            device.setExposureModeCustom(duration: targetDuration, iso: manualISO) { _ in
                                // Queue batched updates instead of immediate dispatch
                                self.queueUpdate(.iso(manualISO))
                                self.queueUpdate(.shutterSpeed(targetDuration))
                            }
                        } else {
                            // No manual ISO - calculate proper ISO for current lighting conditions
                            // to avoid slow transition from previous manual ISO value
                            let currentISO = device.iso
                            let targetOffset = device.exposureTargetOffset
                            
                            // Calculate ideal ISO to achieve zero EV offset
                            // idealISO = currentISO / 2^(targetOffset)
                            var idealISO = currentISO / pow(2.0, targetOffset)
                            
                            // Clamp to device limits
                            let minISO = device.activeFormat.minISO
                            let maxISO = device.activeFormat.maxISO
                            idealISO = min(max(idealISO, minISO), maxISO)
                            
                            self.logger.info("SP transition to auto: Current ISO \(currentISO), Target Offset \(targetOffset)EV, Setting ISO to \(idealISO)")
                            
                            device.setExposureModeCustom(duration: targetDuration, iso: idealISO) { _ in
                                // Queue batched updates instead of immediate dispatch
                                self.queueUpdate(.shutterSpeed(targetDuration))
                                self.queueUpdate(.iso(idealISO))
                            }
                        }
                    }
                    
                case .locked(_, _):
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                    }
                    
                case .recordingLocked(let previousState):
                    // Lock the device's exposure mode to prevent changes during recording
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                        logger.debug("Recording lock applied, device exposure mode set to .locked")
                    } else {
                        logger.warning("Device does not support locked exposure mode during recording")
                    }
                }
                
                device.unlockForConfiguration()
            } catch {
                self.logger.error("Failed to apply exposure state: \(error.localizedDescription)")
                self.delegate?.didEncounterError(.configurationFailed)
            }
        }
    }
    
    // Clean up observers on deinitialization
    deinit {
        removeDeviceObservers()
        cancellables.removeAll()
        logger.info("ExposureService deinitialized, observers removed.")
    }
    
    // MARK: - Performance Optimization Methods
    
    /// Sets up intelligent debouncing for exposure updates
    private func setupUpdateBatching() {
        updateDebouncer = updateSubject
            .debounce(for: .milliseconds(33), scheduler: DispatchQueue.main) // ~30fps max updates
            .sink { [weak self] _ in
                self?.flushPendingUpdates()
            }
        updateDebouncer?.store(in: &cancellables)
        
        // Setup shutter priority debouncing with longer delay for stability
        shutterPriorityDebouncer = shutterPrioritySubject
            .debounce(for: .milliseconds(100), scheduler: exposureAdjustmentQueue) // 100ms for exposure stability
            .sink { [weak self] offset in
                self?.performShutterPriorityAdjustment(offset: offset)
            }
        shutterPriorityDebouncer?.store(in: &cancellables)
    }
    
    /// Adds an update to the pending batch
    private func queueUpdate(_ update: ExposureUpdate) {
        batchLock.lock()
        pendingUpdates.add(update)
        batchLock.unlock()
        updateSubject.send(update)
    }
    
    /// Flushes all pending updates to the delegate in a single batch
    private func flushPendingUpdates() {
        batchLock.lock()
        let batch = pendingUpdates
        pendingUpdates.clear()
        batchLock.unlock()
        
        guard !batch.isEmpty else { return }
        
        // Deliver all batched updates
        if let iso = batch.iso {
            delegate?.didUpdateISO(iso)
        }
        if let shutterSpeed = batch.shutterSpeed {
            delegate?.didUpdateShutterSpeed(shutterSpeed)
        }
        if let whiteBalance = batch.whiteBalance {
            delegate?.didUpdateWhiteBalance(whiteBalance.temperature, tint: whiteBalance.tint)
        }
        if let exposureBias = batch.exposureBias {
            delegate?.didUpdateExposureTargetBias(exposureBias)
        }
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
            // Set initial state based on device mode
            if newDevice.exposureMode == .continuousAutoExposure {
                _ = stateMachine.processEvent(.enableAuto, device: newDevice)
            } else if newDevice.exposureMode == .custom {
                _ = stateMachine.processEvent(.enableManual(iso: nil, duration: nil), device: newDevice)
            }
            logger.info("Initial exposure state set for new device")
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
            
            // Check if we should report ISO based on current state
            switch self.stateMachine.currentState {
            case .shutterPriority(_, let manualISO):
                // Only ignore if manual ISO is set in SP mode
                if manualISO != nil {
                    self.logger.debug("KVO ISO update ignored due to manual ISO override in SP: \(newISO)")
                    return
                }
            default:
                break
            }
            
            // Queue update for batching instead of immediate dispatch
            self.queueUpdate(.iso(newISO))
        }
        
        // Observe exposure duration (shutter speed) changes
        exposureDurationObservation = device.observe(\.exposureDuration, options: [.new]) { [weak self] device, change in
            guard let self = self, let newDuration = change.newValue else { return }
            if device.exposureMode == .continuousAutoExposure || device.exposureMode == .locked {
                // Queue update for batching instead of immediate dispatch
                self.queueUpdate(.shutterSpeed(newDuration))
            }
        }
        
        // Observe white balance gains changes
        whiteBalanceGainsObservation = device.observe(\.deviceWhiteBalanceGains, options: [.new]) { [weak self] device, change in
            // Use the dedicated handler function
            self?.handleWhiteBalanceGainsChange(device, change: change)
        }
        
        // Observe exposure target offset for Shutter Priority
        exposureTargetOffsetObservation = device.observe(\.exposureTargetOffset, options: [.new]) { [weak self] device, change in
            // handleExposureTargetOffsetUpdate will check if we're in shutter priority mode
            self?.handleExposureTargetOffsetUpdate(change: change)
        }
        
        // Observe exposure target bias changes
        exposureBiasObservation = device.observe(\.exposureTargetBias, options: [.new]) { [weak self] device, change in
            guard let self = self, let newBias = change.newValue else { return }
            // Queue update for batching instead of immediate dispatch
            self.queueUpdate(.exposureBias(newBias))
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
        
        // Report ISO - Allow reporting in .custom mode as well
        if device.exposureMode == .continuousAutoExposure || 
           device.exposureMode == .locked || 
           device.exposureMode == .custom {
            queueUpdate(.iso(device.iso))
            logger.debug("Reporting current ISO: \(device.iso) in mode \(device.exposureMode.rawValue)")
        }
        
        // Report Shutter Speed - Allow reporting in .custom mode as well
        if device.exposureMode == .continuousAutoExposure || 
           device.exposureMode == .locked || 
           device.exposureMode == .custom {
            queueUpdate(.shutterSpeed(device.exposureDuration))
            logger.debug("Reporting current Shutter: \(CMTimeGetSeconds(device.exposureDuration))s in mode \(device.exposureMode.rawValue)")
        }
        
        // Report White Balance (Using Safe Helper)
        if device.whiteBalanceMode == .continuousAutoWhiteBalance || device.whiteBalanceMode == .locked {
            if let tempAndTint = safeGetTemperatureAndTint(for: device.deviceWhiteBalanceGains) {
                queueUpdate(.whiteBalance(temperature: tempAndTint.temperature, tint: tempAndTint.tint))
                logger.debug("Reporting current WB Temp: \(tempAndTint.temperature), Tint: \(tempAndTint.tint)")
            } else {
                logger.warning("Could not report initial white balance - conversion failed or gains invalid.")
            }
        }
        
        // Report exposure bias
        queueUpdate(.exposureBias(device.exposureTargetBias))
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
                    let currentTempAndTint = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                    self?.queueUpdate(.whiteBalance(temperature: currentTempAndTint.temperature, tint: currentTempAndTint.tint))
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
    
    func updateISO(_ iso: Float, fromUser: Bool = false) {
        guard let device = device else { 
            logger.error("No camera device available")
            return 
        }
        
        // Prevent changes while recording is locked
        if case .recordingLocked = stateMachine.currentState {
            logger.warning("Cannot update ISO while recording with exposure lock")
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
        
        // Handle based on current state
        switch stateMachine.currentState {
        case .shutterPriority(_, _):
            if fromUser {
                // User is manually overriding ISO in SP mode
                _ = stateMachine.processEvent(.overrideISOInShutterPriority(iso: clampedISO), device: device)
            } else {
                // System trying to update ISO in SP mode - ignore
                logger.debug("System ISO update ignored in SP mode")
                return
            }
        case .auto:
            // Switch to manual mode when ISO is set
            _ = stateMachine.processEvent(.enableManual(iso: clampedISO, duration: nil), device: device)
        case .manual:
            // Update ISO in manual mode
            _ = stateMachine.processEvent(.enableManual(iso: clampedISO, duration: nil), device: device)
        case .locked, .recordingLocked:
            logger.warning("Cannot update ISO while exposure is locked")
            return
        }
    }
    
    func updateShutterSpeed(_ speed: CMTime) {
        guard let device = device else {
            logger.error("No camera device available for shutter speed update")
            return
        }
        
        // Prevent changes while recording is locked
        if case .recordingLocked = stateMachine.currentState {
            logger.warning("Cannot update shutter speed while recording with exposure lock")
            return
        }
        
        // Check current state
        switch stateMachine.currentState {
        case .shutterPriority:
            logger.info("updateShutterSpeed called while Shutter Priority is active. Ignoring.")
            return
        case .locked, .recordingLocked:
            logger.warning("Cannot update shutter speed while exposure is locked")
            return
        case .auto:
            // Switch to manual mode when shutter speed is set
            _ = stateMachine.processEvent(.enableManual(iso: nil, duration: speed), device: device)
        case .manual:
            // Update shutter speed in manual mode
            _ = stateMachine.processEvent(.enableManual(iso: nil, duration: speed), device: device)
        }
    }
    
    func updateShutterAngle(_ angle: Double, frameRate: Double) {
        // Check if Shutter Priority is active
        if case .shutterPriority = stateMachine.currentState {
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
        
        // Use state machine to set manual exposure with specific values
        _ = stateMachine.processEvent(.enableManual(iso: iso, duration: duration), device: device)
    }
    
    func setAutoExposureEnabled(_ enabled: Bool) {
        guard let device = device else { return }
        
        // Prevent changes while recording is locked
        if case .recordingLocked = stateMachine.currentState {
            logger.warning("Cannot change exposure mode while recording with exposure lock")
            return
        }
        
        // Check if we're in shutter priority mode
        if case .shutterPriority(_, let manualISO) = stateMachine.currentState {
            // In SP mode, toggle between manual ISO override and auto ISO
            if enabled && manualISO != nil {
                // Clear manual ISO override to return to auto ISO in SP
                _ = stateMachine.processEvent(.clearManualISOOverride, device: device)
            }
            // If disabling auto in SP mode, the user will set ISO manually via updateISO
            // No need to change state here
            return
        }
        
        // Normal auto/manual mode switching
        if enabled {
            _ = stateMachine.processEvent(.enableAuto, device: device)
        } else {
            _ = stateMachine.processEvent(.enableManual(iso: nil, duration: nil), device: device)
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
        
        logger.info("[ExposureLock] Request to set lock=\(locked) for device: \(device.localizedName)")

        if locked {
            _ = stateMachine.processEvent(.lock, device: device)
        } else {
            _ = stateMachine.processEvent(.unlock, device: device)
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
                    let currentTempAndTint = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                    self?.queueUpdate(.whiteBalance(temperature: currentTempAndTint.temperature, tint: currentTempAndTint.tint))
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
        
        _ = stateMachine.processEvent(.enableShutterPriority(duration: duration), device: device)
        
        // If initial ISO is provided, override it
        if let initialISO = initialISO {
            _ = stateMachine.processEvent(.overrideISOInShutterPriority(iso: initialISO), device: device)
        }
    }
    
    func disableShutterPriority() {
        guard let device = device else {
            logger.error("SP Disable: No device available.")
            return
        }
        
        // Always revert to auto when disabling SP
        _ = stateMachine.processEvent(.enableAuto, device: device)
        targetShutterDuration = nil
        logger.info("Disabling Shutter Priority.")
    }
    // --------------------------------

    // --- Optimized exposure target offset handling ---
    private func handleExposureTargetOffsetUpdate(change: NSKeyValueObservedChange<Float>) {
        // Check if we're in shutter priority mode
        guard case .shutterPriority(_, let manualISO) = stateMachine.currentState,
              manualISO == nil, // Only adjust if no manual ISO override
              let newOffset = change.newValue else {
            return
        }
        
        // Only adjust if EV offset is significant
        guard abs(newOffset) > evOffsetThreshold else {
            return
        }
        
        // Send to debounced handler instead of immediate processing
        shutterPrioritySubject.send(newOffset)
    }
    
    /// Performs the actual shutter priority adjustment after debouncing
    private func performShutterPriorityAdjustment(offset: Float) {
        guard case .shutterPriority(let targetDuration, let manualISO) = stateMachine.currentState,
              manualISO == nil,
              let currentDevice = device else { return }
        
        let currentISO = currentDevice.iso
        let minISO = currentDevice.activeFormat.minISO
        let maxISO = currentDevice.activeFormat.maxISO
        
        // Calculate the ideal ISO to compensate for the offset
        var idealISO = currentISO / pow(2.0, offset)
        idealISO = min(max(idealISO, minISO), maxISO)
        
        // Only adjust if the change is significant enough
        let percentageChange = abs(idealISO - currentISO) / currentISO
        guard percentageChange > isoPercentageThreshold else {
            return
        }
        
        logger.debug("SP Adjust: Offset \(String(format: "%.2f", offset))EV, Current ISO \(String(format: "%.1f", currentISO)), Ideal ISO \(String(format: "%.1f", idealISO))")
        
        do {
            try currentDevice.lockForConfiguration()
            currentDevice.setExposureModeCustom(duration: targetDuration, iso: idealISO) { [weak self] _ in
                self?.logger.debug("SP Adjustment Applied: ISO set to \(String(format: "%.1f", idealISO))")
            }
            currentDevice.unlockForConfiguration()
        } catch {
            logger.error("SP Adjust: Error setting custom exposure: \(error.localizedDescription)")
            currentDevice.unlockForConfiguration()
        }
    }
    // --------------------------

    // MARK: - Recording Lock
    
    /// Locks exposure for recording, preserving the current state
    func lockExposureForRecording() {
        guard let device = device else {
            logger.error("No camera device available for recording lock")
            return
        }
        
        _ = stateMachine.processEvent(.startRecording, device: device)
        logger.info("🔒 Locked exposure for recording (state: \(String(describing: self.stateMachine.currentState)))")
    }
    
    /// Unlocks exposure after recording, restoring the previous state
    func unlockExposureAfterRecording() {
        guard let device = device else {
            logger.error("No camera device available for recording unlock")
            return
        }
        
        _ = stateMachine.processEvent(.stopRecording, device: device)
        logger.info("🔓 Unlocked exposure after recording (restored state: \(String(describing: self.stateMachine.currentState)))")
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
            // Queue update for batching instead of immediate dispatch
            queueUpdate(.whiteBalance(temperature: tempAndTint.temperature, tint: tempAndTint.tint))
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
        
        // Prevent changes while recording is locked
        if case .recordingLocked = stateMachine.currentState {
            logger.warning("[ExposureBias] Cannot change exposure bias while recording with exposure lock")
            return
        }

        // Only allow in continuousAutoExposure mode
        guard device.exposureMode == .continuousAutoExposure else {
            logger.warning("[ExposureBias] Cannot set EV bias unless in continuousAutoExposure mode. Current mode: \(device.exposureMode.rawValue)")
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
                self?.queueUpdate(.exposureBias(clampedBias))
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
                if case .shutterPriority = self.stateMachine.currentState {
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
        lastKnownGoodState = stateMachine.currentState
    }

    func restoreAfterLensSwitch() {
        guard let state = lastKnownGoodState,
              let device = device else { return }
        
        // Restore the state machine state
        switch state {
        case .auto:
            _ = stateMachine.processEvent(.enableAuto, device: device)
        case .manual(let iso, let duration):
            _ = stateMachine.processEvent(.enableManual(iso: iso, duration: duration), device: device)
        case .shutterPriority(let duration, let manualISO):
            _ = stateMachine.processEvent(.enableShutterPriority(duration: duration), device: device)
            if let manualISO = manualISO {
                _ = stateMachine.processEvent(.overrideISOInShutterPriority(iso: manualISO), device: device)
            }
        case .locked(let iso, let duration):
            _ = stateMachine.processEvent(.enableManual(iso: iso, duration: duration), device: device)
            _ = stateMachine.processEvent(.lock, device: device)
        case .recordingLocked:
            // Should not happen during lens switch
            logger.warning("Unexpected recording locked state during lens switch restore")
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
                  case .shutterPriority = self.stateMachine.currentState else { return }
            
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
            queueUpdate(.whiteBalance(temperature: currentTempAndTint.temperature, tint: currentTempAndTint.tint))
        } catch {
            logger.error("Failed to change white-balance mode: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed)
        }
    }

    func setManualISOInSP(_ manual: Bool) {
        guard let device = device else { return }
        
        if manual {
            // This should only be called when in SP mode
            if case .shutterPriority = stateMachine.currentState {
                // ISO will be set via updateISO with fromUser=true
                logger.debug("Manual ISO override enabled in SP mode")
            }
        } else {
            // Clear manual ISO override
            _ = stateMachine.processEvent(.clearManualISOOverride, device: device)
        }
    }
}

// ExposureMode moved to ExposureUIViewModel for UI state management 