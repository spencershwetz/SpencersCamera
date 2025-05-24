import SwiftUI
import AVFoundation
import CoreMedia
import Combine
import os.log

/// A focused ViewModel that handles exposure-specific UI state and logic
/// This decouples UI-specific exposure handling from the main CameraViewModel
class ExposureUIViewModel: ObservableObject {
    private let logger = Logger(subsystem: "com.camera", category: "ExposureUIViewModel")
    
    // MARK: - Published UI State
    @Published var currentExposureMode: ExposureMode = .auto
    @Published var isAutoExposureEnabled: Bool = true
    @Published var isExposureLocked: Bool = false
    @Published var isShutterPriorityEnabled: Bool = false
    @Published var isManualISOInSP: Bool = false
    @Published var exposureBias: Float = 0.0
    
    // MARK: - Device Limits (updated from ExposureService)
    @Published var minISO: Float = 50
    @Published var maxISO: Float = 1600
    @Published var minExposureBias: Float = -2.0
    @Published var maxExposureBias: Float = 2.0
    
    // MARK: - Current Values (received from ExposureService via CameraViewModel)
    @Published var currentISO: Float = 100
    @Published var currentShutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 60)
    @Published var currentWhiteBalance: Float = 5000
    @Published var currentTint: Float = 0
    
    // MARK: - UI Configuration
    @Published var selectedFrameRate: Double = 30.0
    
    // MARK: - Private State
    private var cancellables = Set<AnyCancellable>()
    private weak var cameraViewModel: CameraViewModel?
    
    // MARK: - Initialization
    init(cameraViewModel: CameraViewModel) {
        self.cameraViewModel = cameraViewModel
        setupBindings()
    }
    
    // MARK: - Setup
    private func setupBindings() {
        // Observe exposure lock changes and update UI state accordingly
        $isExposureLocked
            .sink { [weak self] locked in
                self?.handleExposureLockChange(locked)
            }
            .store(in: &cancellables)
        
        // Update exposure mode when auto exposure state changes
        $isAutoExposureEnabled
            .sink { [weak self] enabled in
                self?.handleAutoExposureChange(enabled)
            }
            .store(in: &cancellables)
        
        // Handle shutter priority state changes
        $isShutterPriorityEnabled
            .sink { [weak self] enabled in
                self?.handleShutterPriorityChange(enabled)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Interface
    
    /// Updates the current exposure mode and synchronizes related UI state
    func updateExposureMode(_ mode: ExposureMode) {
        guard currentExposureMode != mode else { return }
        
        logger.info("Updating exposure mode from \(self.currentExposureMode.rawValue) to \(mode.rawValue)")
        currentExposureMode = mode
        
        // Update related UI state to match
        switch mode {
        case .auto:
            isAutoExposureEnabled = true
            isExposureLocked = false
            isShutterPriorityEnabled = false
        case .manual:
            isAutoExposureEnabled = false
            isExposureLocked = false
            isShutterPriorityEnabled = false
        case .shutterPriority:
            isAutoExposureEnabled = false
            isExposureLocked = false
            isShutterPriorityEnabled = true
        case .locked:
            isExposureLocked = true
        }
    }
    
    /// Sets auto exposure enabled/disabled and updates the camera
    func setAutoExposureEnabled(_ enabled: Bool) {
        guard isAutoExposureEnabled != enabled else { return }
        
        isAutoExposureEnabled = enabled
        updateExposureMode(enabled ? .auto : .manual)
        cameraViewModel?.exposureService.setAutoExposureEnabled(enabled)
    }
    
    /// Sets exposure lock and updates the camera
    func setExposureLock(locked: Bool) {
        guard isExposureLocked != locked else { return }
        
        isExposureLocked = locked
        cameraViewModel?.exposureService.setExposureLock(locked: locked)
    }
    
    /// Enables/disables shutter priority mode
    func setShutterPriorityEnabled(_ enabled: Bool) {
        guard isShutterPriorityEnabled != enabled else { return }
        
        isShutterPriorityEnabled = enabled
        
        if enabled {
            enableShutterPriority()
        } else {
            disableShutterPriority()
        }
    }
    
    /// Updates exposure bias (EV compensation)
    func setExposureBias(_ bias: Float) {
        let clampedBias = min(max(bias, minExposureBias), maxExposureBias)
        exposureBias = clampedBias
        cameraViewModel?.exposureService.updateExposureTargetBias(clampedBias)
    }
    
    /// Updates ISO value through the camera
    func updateISO(_ iso: Float) {
        let clampedISO = min(max(iso, minISO), maxISO)
        logger.debug("ExposureUIViewModel.updateISO: \(clampedISO), mode: \(currentExposureMode)")
        
        // Handle auto exposure toggle and SP mode logic
        if cameraViewModel?.isAutoExposureEnabled == true {
            setAutoExposureEnabled(false)
        }
        
        // Handle SP mode manual ISO override
        if currentExposureMode == .shutterPriority && !isManualISOInSP {
            setManualISOInSP(true)
        }
        
        cameraViewModel?.exposureService.updateISO(clampedISO, fromUser: true)
    }
    
    /// Updates shutter speed through the camera
    func updateShutterSpeed(_ speed: CMTime) {
        cameraViewModel?.exposureService.updateShutterSpeed(speed)
    }
    
    /// Updates shutter angle (converts to shutter speed based on frame rate)
    func updateShutterAngle(_ angle: Double) {
        guard let frameRate = cameraViewModel?.selectedFrameRate else { return }
        cameraViewModel?.exposureService.updateShutterAngle(angle, frameRate: frameRate)
    }
    
    /// Updates white balance temperature
    func updateWhiteBalance(_ temperature: Float) {
        cameraViewModel?.exposureService.updateWhiteBalance(temperature)
    }
    
    /// Updates white balance tint
    func updateTint(_ tint: Float) {
        cameraViewModel?.exposureService.updateTint(tint, currentWhiteBalance: currentWhiteBalance)
    }
    
    /// Sets manual ISO override in shutter priority mode
    func setManualISOInSP(_ manual: Bool) {
        isManualISOInSP = manual
        cameraViewModel?.exposureService.setManualISOInSP(manual)
    }
    
    // MARK: - Device State Updates (called by CameraViewModel)
    
    /// Updates device limits when camera device changes
    func updateDeviceLimits(minISO: Float, maxISO: Float, minBias: Float, maxBias: Float) {
        self.minISO = minISO
        self.maxISO = maxISO
        self.minExposureBias = minBias
        self.maxExposureBias = maxBias
    }
    
    /// Updates current ISO value from device
    func updateCurrentISO(_ iso: Float) {
        currentISO = iso
    }
    
    /// Updates current shutter speed from device
    func updateCurrentShutterSpeed(_ speed: CMTime) {
        currentShutterSpeed = speed
    }
    
    /// Updates current white balance from device
    func updateCurrentWhiteBalance(temperature: Float, tint: Float) {
        currentWhiteBalance = temperature
        currentTint = tint
    }
    
    /// Updates current exposure bias from device
    func updateCurrentExposureBias(_ bias: Float) {
        exposureBias = bias
    }
    
    // MARK: - Computed Properties for UI
    
    /// User-friendly string for current exposure mode
    var exposureModeDisplayText: String {
        switch currentExposureMode {
        case .auto:
            return "Auto"
        case .manual:
            return "Manual"
        case .shutterPriority:
            return "Shutter Priority"
        case .locked:
            return "Locked"
        }
    }
    
    /// Whether manual controls should be enabled in UI
    var areManualControlsEnabled: Bool {
        return currentExposureMode == .manual || currentExposureMode == .shutterPriority
    }
    
    /// Whether ISO can be manually adjusted
    var canAdjustISO: Bool {
        switch currentExposureMode {
        case .auto, .locked:
            return false
        case .manual:
            return true
        case .shutterPriority:
            return true // Can override with manual ISO
        }
    }
    
    /// Whether shutter speed can be manually adjusted
    var canAdjustShutterSpeed: Bool {
        switch currentExposureMode {
        case .auto, .locked, .shutterPriority:
            return false
        case .manual:
            return true
        }
    }
    
    /// Whether exposure bias can be adjusted
    var canAdjustExposureBias: Bool {
        return currentExposureMode == .auto
    }
    
    // MARK: - Private Helpers
    
    private func handleExposureLockChange(_ locked: Bool) {
        if locked {
            updateExposureMode(.locked)
        } else {
            // Restore previous mode based on current state
            if isShutterPriorityEnabled {
                updateExposureMode(.shutterPriority)
            } else if isAutoExposureEnabled {
                updateExposureMode(.auto)
            } else {
                updateExposureMode(.manual)
            }
        }
    }
    
    private func handleAutoExposureChange(_ enabled: Bool) {
        if enabled && !isExposureLocked && !isShutterPriorityEnabled {
            updateExposureMode(.auto)
        } else if !enabled && !isExposureLocked && !isShutterPriorityEnabled {
            updateExposureMode(.manual)
        }
    }
    
    private func handleShutterPriorityChange(_ enabled: Bool) {
        if enabled {
            updateExposureMode(.shutterPriority)
        } else if isAutoExposureEnabled {
            updateExposureMode(.auto)
        } else {
            updateExposureMode(.manual)
        }
    }
    
    private func enableShutterPriority() {
        // Calculate 180° shutter duration based on current frame rate
        guard let frameRate = cameraViewModel?.selectedFrameRate else { return }
        let duration = CMTimeMakeWithSeconds(1.0 / (2.0 * frameRate), preferredTimescale: 1_000_000)
        cameraViewModel?.exposureService.enableShutterPriority(duration: duration)
        updateExposureMode(.shutterPriority)
    }
    
    private func disableShutterPriority() {
        cameraViewModel?.exposureService.disableShutterPriority()
        isManualISOInSP = false
        updateExposureMode(.auto)
    }
    
    /// Syncs the exposure mode from ExposureService to this UI model
    func syncExposureMode() {
        guard let service = cameraViewModel?.exposureService else { return }
        let serviceMode = service.currentExposureMode
        updateExposureMode(serviceMode)
    }
}

// ExposureMode enum is now defined in Models/ExposureMode.swift