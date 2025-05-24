import AVFoundation
import os.log
import UIKit
import Foundation

protocol CameraDeviceServiceDelegate: AnyObject {
    func didUpdateCurrentLens(_ lens: CameraLens)
    func didUpdateZoomFactor(_ factor: CGFloat)
    func didEncounterError(_ error: CameraError)
    var isExposureCurrentlyLocked: Bool { get }
    var isVideoStabilizationCurrentlyEnabled: Bool { get }
}

class CameraDeviceService {
    private let logger = Logger(subsystem: "com.camera", category: "CameraDeviceService")
    private weak var delegate: CameraDeviceServiceDelegate?
    private var session: AVCaptureSession
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var lastZoomFactor: CGFloat = 1.0
    private let cameraQueue = DispatchQueue(label: "com.camera.device-service")
    private var videoFormatService: VideoFormatService
    private var exposureService: ExposureService
    
    // Public computed property to access the current device
    var currentDevice: AVCaptureDevice? {
        return device
    }
    
    init(session: AVCaptureSession, videoFormatService: VideoFormatService, exposureService: ExposureService, delegate: CameraDeviceServiceDelegate) {
        self.session = session
        self.videoFormatService = videoFormatService
        self.exposureService = exposureService
        self.delegate = delegate
    }
    
    func setDevice(_ device: AVCaptureDevice) {
        self.device = device
        logger.info("📸 Set initial device: \(device.localizedName)")
    }
    
    func setVideoDeviceInput(_ input: AVCaptureDeviceInput) {
        self.videoDeviceInput = input
        logger.info("📸 Set initial video input: \(input.device.localizedName)")
    }
    
    private func configureSession(for newDevice: AVCaptureDevice, lens: CameraLens) throws {
        // === ADDED: Store existing audio input ===
        let audioInput = session.inputs.first(where: { $0 is AVCaptureDeviceInput && ($0 as! AVCaptureDeviceInput).device.hasMediaType(.audio) }) as? AVCaptureDeviceInput
        if audioInput != nil {
            logger.info("🎤 Preserving existing audio input.")
        }
        // =========================================

        // Remove existing inputs and outputs
        session.inputs.forEach { session.removeInput($0) }
        
        // Add new VIDEO input
        let newInput = try AVCaptureDeviceInput(device: newDevice)
        guard session.canAddInput(newInput) else {
            logger.error("❌ Cannot add input for \(newDevice.localizedName)")
            throw CameraError.invalidDeviceInput
        }
        
        session.addInput(newInput)
        videoDeviceInput = newInput
        device = newDevice
        
        // ADDED: Update ExposureService's device reference
        exposureService.setDevice(newDevice)
        logger.info("⚙️ [configureSession] Updated ExposureService device to \(newDevice.localizedName)")

        // === ADDED: Re-add audio input ===
        if let audioInput = audioInput {
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
                logger.info("🎤 Re-added preserved audio input.")
            } else {
                logger.warning("🎤 Could not re-add preserved audio input.")
                // Optionally throw an error or handle differently
            }
        }
        // ================================
        
        // Configure the new device
        try newDevice.lockForConfiguration()
        defer { newDevice.unlockForConfiguration() } // Ensure unlock even on error
        
        // Always find the best format based on current settings and Apple Log state
        logger.info("⚙️ [configureSession] Finding best format for device \(newDevice.localizedName)...")
        guard let currentFPS = videoFormatService.getCurrentFrameRateFromDelegate(),
              let currentResolution = videoFormatService.getCurrentResolutionFromDelegate() else {
            logger.error("❌ [configureSession] Could not get current FPS/Resolution from delegate.")
            // Decide how to handle this - maybe use device defaults?
            // For now, throw an error as settings are crucial.
            throw CameraError.configurationFailed(message: "Missing delegate settings for session config.")
        }
        
        let requireLog = videoFormatService.isAppleLogEnabled
        logger.info("Delegate settings: Res=\(currentResolution.rawValue), FPS=\(currentFPS), RequireLog=\(requireLog)")
        
        guard let selectedFormat = videoFormatService.findBestFormat(for: newDevice, resolution: currentResolution, frameRate: currentFPS, requireAppleLog: requireLog) else {
            logger.error("❌ [configureSession] No suitable format found matching current settings (Res=\(currentResolution.rawValue), FPS=\(currentFPS), AppleLog=\(requireLog)).")
            // Fallback? Inform user? Throw?
            throw CameraError.configurationFailed(message: "No matching format found for current settings.")
        }
        
        // Set the format
        if newDevice.activeFormat != selectedFormat {
            newDevice.activeFormat = selectedFormat
            logger.info("✅ [configureSession] Set active format to: \(selectedFormat.description)")
        } else {
            logger.info("ℹ️ [configureSession] Device already using the target format.")
        }

        // ---> ADDED: Re-apply specific frame duration lock <---
        let frameDuration = self.videoFormatService.getFrameDuration(for: currentFPS)
        if newDevice.activeVideoMinFrameDuration != frameDuration || newDevice.activeVideoMaxFrameDuration != frameDuration {
            newDevice.activeVideoMinFrameDuration = frameDuration
            newDevice.activeVideoMaxFrameDuration = frameDuration
            logger.info("✅ [configureSession] Applied specific frame duration lock for \(currentFPS) FPS.")
        } else {
            logger.info("ℹ️ [configureSession] Device already locked to the correct frame duration for \(currentFPS) FPS.")
        }
        // ---> END Added Code <---
        
        // ---> ADDED: Configure Color Space and HDR based on format and Log setting <---
        logger.info("🎨 [configureSession] Configuring color space and HDR...")
        let targetColorSpace: AVCaptureColorSpace
        if requireLog, selectedFormat.supportedColorSpaces.contains(.appleLog) {
            targetColorSpace = .appleLog
            logger.info("🎨 [configureSession] Target color space: Apple Log (requested and supported).")
        } else if requireLog {
            logger.warning("⚠️ [configureSession] Apple Log requested but NOT supported by format \(selectedFormat.description). Falling back.")
            targetColorSpace = selectedFormat.supportedColorSpaces.contains(.P3_D65) ? .P3_D65 : .sRGB
        } else {
            targetColorSpace = selectedFormat.supportedColorSpaces.contains(.P3_D65) ? .P3_D65 : .sRGB
            logger.info("🎨 [configureSession] Target color space: \(targetColorSpace == .P3_D65 ? "P3_D65" : "sRGB") (Log not requested).")
        }

        if newDevice.activeColorSpace != targetColorSpace {
            // Verify the color space is supported by the active format before setting
            if selectedFormat.supportedColorSpaces.contains(targetColorSpace) {
                newDevice.activeColorSpace = targetColorSpace
                logger.info("✅ [configureSession] Set activeColorSpace to \(targetColorSpace.rawValue).")
            } else {
                logger.error("❌ [configureSession] Target color space \(targetColorSpace.rawValue) is not supported by selected format")
                logger.info("ℹ️ [configureSession] Supported color spaces: \(selectedFormat.supportedColorSpaces.map { $0.rawValue })")
                // Fall back to first supported color space
                if let fallbackColorSpace = selectedFormat.supportedColorSpaces.first {
                    newDevice.activeColorSpace = fallbackColorSpace
                    logger.info("⚠️ [configureSession] Using fallback color space: \(fallbackColorSpace.rawValue)")
                }
            }
        } else {
             logger.info("ℹ️ [configureSession] activeColorSpace already set to \(targetColorSpace.rawValue).")
        }

        // Configure HDR based on whether Apple Log is active AND supported
        let shouldEnableHDR = (targetColorSpace == .appleLog) && selectedFormat.isVideoHDRSupported
        if shouldEnableHDR {
            // Enable HDR for Apple Log if supported
            // Check if we need to change state (either HDR is off or auto-adjust is on)
            if !newDevice.isVideoHDREnabled || newDevice.automaticallyAdjustsVideoHDREnabled {
                logger.info("☀️ [configureSession] Enabling HDR for Apple Log...")
                newDevice.automaticallyAdjustsVideoHDREnabled = false // MUST set this first to allow manual control
                newDevice.isVideoHDREnabled = true
                logger.info("✅ [configureSession] Enabled HDR video mode for Apple Log.")
            } else {
                logger.info("ℹ️ [configureSession] HDR video mode already enabled for Apple Log.")
            }
        } else {
            // Ensure Automatic HDR is enabled for non-Apple Log modes
            if !newDevice.automaticallyAdjustsVideoHDREnabled {
                 logger.info("☀️ [configureSession] Enabling automatic HDR adjustment for non-Log mode...")
                newDevice.automaticallyAdjustsVideoHDREnabled = true
                logger.info("✅ [configureSession] Enabled automatic HDR adjustment.")
            } else {
                logger.info("ℹ️ [configureSession] Automatic HDR adjustment already enabled.")
            }
            // IMPORTANT: Do NOT manually set isVideoHDREnabled when automaticallyAdjustsVideoHDREnabled is true
        }
        // ---> END Color Space / HDR Configuration <---

        // Check if exposure should be locked (during recording or shutter priority)
        let shouldLockExposure = delegate?.isExposureCurrentlyLocked ?? false
        if shouldLockExposure {
            logger.info("🔒 [configureSession] Exposure lock required, setting mode to .locked")
            if newDevice.isExposureModeSupported(.locked) {
                newDevice.exposureMode = .locked
            }
        } else {
            // Set default exposure mode only if not locked
            if newDevice.isExposureModeSupported(.continuousAutoExposure) {
                newDevice.exposureMode = .continuousAutoExposure
            }
        }

        // Set other default configurations like focus (if needed here)
        if newDevice.isFocusModeSupported(.continuousAutoFocus) {
            newDevice.focusMode = .continuousAutoFocus
        }
        // Note: Frame rate lock, color space, and HDR are now handled within this method.

        // === MOVE color space setting to after all other device configuration ===
        if newDevice.activeColorSpace != targetColorSpace {
            // Verify the color space is supported by the active format before setting
            if selectedFormat.supportedColorSpaces.contains(targetColorSpace) {
                newDevice.activeColorSpace = targetColorSpace
                logger.info("✅ [configureSession] (FINAL) Set activeColorSpace to \(targetColorSpace.rawValue) after all configuration.")
            } else {
                logger.error("❌ [configureSession] (FINAL) Target color space \(targetColorSpace.rawValue) is not supported by selected format")
                logger.info("ℹ️ [configureSession] (FINAL) Supported color spaces: \(selectedFormat.supportedColorSpaces.map { $0.rawValue })")
                // Fall back to first supported color space
                if let fallbackColorSpace = selectedFormat.supportedColorSpaces.first {
                    newDevice.activeColorSpace = fallbackColorSpace
                    logger.info("⚠️ [configureSession] (FINAL) Using fallback color space: \(fallbackColorSpace.rawValue)")
                }
            }
        } else {
            logger.info("ℹ️ [configureSession] (FINAL) activeColorSpace already set to \(targetColorSpace.rawValue) after all configuration.")
        }
        logger.info("🔍 [configureSession] (FINAL) Device reports activeColorSpace: \(newDevice.activeColorSpace.rawValue)")

        logger.info("✅ Successfully configured session for \(newDevice.localizedName)")
    }
    
    func switchToLens(_ lens: CameraLens) {
        // Capture the interface orientation on the main thread before dispatching
        let activeScene = UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first
        let currentInterfaceOrientation = activeScene?.interfaceOrientation ?? .portrait

        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            
            // For 2x zoom, use digital zoom on the wide angle camera
            if lens == .x2 {
                if let currentDevice = self.device,
                   currentDevice.deviceType == .builtInWideAngleCamera {
                    // Digital zoom is safe during recording
                    self.setDigitalZoom(to: lens.zoomFactor, on: currentDevice)
                } else {
                    // Switching to wide *before* digital zoom requires physical switch
                    self.switchToPhysicalLens(.wide, thenSetZoomTo: lens.zoomFactor, currentInterfaceOrientation: currentInterfaceOrientation)
                }
                return
            }
            
            // For all other lenses, try to switch physical device
            self.switchToPhysicalLens(lens, thenSetZoomTo: 1.0, currentInterfaceOrientation: currentInterfaceOrientation)
        }
    }
    
    private func switchToPhysicalLens(_ lens: CameraLens, thenSetZoomTo zoomFactor: CGFloat, currentInterfaceOrientation: UIInterfaceOrientation) {
        logger.info("🔄 Attempting to switch to \(lens.rawValue)× lens")
        
        // Get discovery session for all possible back cameras
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        )
        
        logger.info("📸 Available devices: \(discoverySession.devices.map { "\($0.localizedName) (\($0.deviceType))" })")
        
        // Find the device we want
        guard let newDevice = discoverySession.devices.first(where: { $0.deviceType == lens.deviceType }) else {
            logger.error("❌ Device not available for \(lens.rawValue)× lens")
            DispatchQueue.main.async {
                self.delegate?.didEncounterError(.deviceUnavailable)
            }
            return
        }
        
        // Check if we're already on this device
        if let currentDevice = device, currentDevice == newDevice {
            logger.debug("🔄 Lens switch requested for \(lens.rawValue)x, but already on this device. Setting digital zoom.")
            setDigitalZoom(to: zoomFactor, on: currentDevice)
            return
        }
        
        // Configure session with new device
        let wasRunning = session.isRunning
        logger.debug("🔄 Lens switch: Session was running: \(wasRunning)")
        if wasRunning {
            logger.debug("🔄 Lens switch: Stopping session...")
            session.stopRunning()
            logger.debug("🔄 Lens switch: Session stopped.")
        }
        
        // Trigger a memory cleanup before configuring the session
        logger.debug("🔄 Lens switch: Triggering memory cleanup...")
        autoreleasepool {
            // Force immediate cleanup of any autoreleased objects
            triggerMemoryCleanup()
        }
        
        logger.debug("🔄 Lens switch: Beginning configuration for \(newDevice.localizedName) (\(lens.rawValue)x)")
        session.beginConfiguration()
        logger.debug("🔄 Lens switch: Configuration begun.")
        
        let previousFormat = device?.activeFormat // Log previous format
        logger.debug("🔄 Lens switch: Previous active format: \(previousFormat?.description ?? "None")")
        
        do {
            try configureSession(for: newDevice, lens: lens)
            logger.debug("🔄 Lens switch: Configured session for new device. New active format: \(newDevice.activeFormat.description)")
            
            // Update the internal device reference in VideoFormatService
            videoFormatService.setDevice(newDevice)
            
            logger.debug("🔄 Lens switch: Committing configuration...")
            session.commitConfiguration()
            logger.debug("🔄 Lens switch: Configuration committed.")

            // ---> ADDED: Re-apply stabilization setting after configuration commit <---
            if let videoDataOutput = session.outputs.first(where: { $0 is AVCaptureVideoDataOutput }) as? AVCaptureVideoDataOutput,
               let connection = videoDataOutput.connection(with: .video) {
                
                // Read setting from delegate
                let isStabilizationEnabled = delegate?.isVideoStabilizationCurrentlyEnabled ?? false

                let targetMode: AVCaptureVideoStabilizationMode = isStabilizationEnabled ? .standard : .off
                
                // Check if the *current device's active format* supports the *target* mode
                if let currentDevice = self.device { // Use the current device
                    if currentDevice.activeFormat.isVideoStabilizationModeSupported(targetMode) {
                        // Apply stabilization if supported and different from current
                        if connection.preferredVideoStabilizationMode != targetMode {
                            connection.preferredVideoStabilizationMode = targetMode
                            logger.info("✅🔄 Lens switch: Applied video stabilization mode: \(targetMode.rawValue)")
                        } else {
                            logger.info("ℹ️🔄 Lens switch: Video stabilization mode already set to \(targetMode.rawValue).")
                        }
                    } else if isStabilizationEnabled { 
                        // If standard/target mode isn't supported, try falling back to .auto
                        if currentDevice.activeFormat.isVideoStabilizationModeSupported(.auto) {
                             if connection.preferredVideoStabilizationMode != .auto {
                                 connection.preferredVideoStabilizationMode = .auto
                                 logger.info("✅🔄 Lens switch: Applied fallback video stabilization mode: .auto")
                             } else {
                                 logger.info("ℹ️🔄 Lens switch: Video stabilization mode already set to fallback: .auto")
                             }
                        } else {
                            logger.warning("⚠️🔄 Lens switch: Target stabilization mode \(targetMode.rawValue) and fallback .auto not supported by device format.")
                            // Optionally force it off if enabling is not possible
                            if connection.preferredVideoStabilizationMode != .off {
                                connection.preferredVideoStabilizationMode = .off
                                logger.info("✅🔄 Lens switch: Forcing stabilization off as requested mode/fallback are unsupported.")
                            }
                        }
                    } else { // isStabilizationEnabled is false
                         // Ensure it's off if the target mode was .off and it wasn't already
                         if connection.preferredVideoStabilizationMode != .off {
                             // Check if .off is actually supported (it always should be)
                             if currentDevice.activeFormat.isVideoStabilizationModeSupported(.off) {
                                 connection.preferredVideoStabilizationMode = .off
                                 logger.info("✅🔄 Lens switch: Applied video stabilization mode: .off")
                             } else {
                                 logger.warning("⚠️🔄 Lens switch: Could not explicitly set stabilization mode to .off.")
                             }
                         } else {
                              logger.info("ℹ️🔄 Lens switch: Video stabilization mode already set to .off.")
                         }
                    }
                } else {
                     logger.warning("⚠️🔄 Lens switch: Could not get current device to check stabilization support.")
                }
            } else {
                logger.warning("⚠️🔄 Lens switch: Could not find video data output or connection to apply stabilization.")
            }
            // ---> END Stabilization Code <---
            
            // Apply digital zoom INSTANTLY if needed after the physical switch
            if zoomFactor != 1.0 {
                 logger.debug("🔄 Lens switch: Applying digital zoom factor \(zoomFactor) after physical switch to \(newDevice.localizedName).")
                 // Use the modified setDigitalZoom which is now instant
                 self.setDigitalZoom(to: zoomFactor, on: newDevice)
            }
            
            if wasRunning {
                logger.debug("🔄 Lens switch: Starting session...")
                session.startRunning()
                logger.debug("🔄 Lens switch: Session started.")
            }

            // ADDED: Delay and re-apply exposure lock state AFTER starting session
            Task { // Use a Task for sleep
                try? await Task.sleep(for: .milliseconds(50)) // Short delay
                
                if self.delegate?.isExposureCurrentlyLocked == true {
                    self.logger.info("🔄 Lens switch (Delayed): Exposure lock is active, re-applying lock via ExposureService...")
                    self.exposureService.setExposureLock(locked: true)
                }
                // Note: We don't call setExposureLock(locked: false) anymore as it can interfere
                // with recording locks. The exposure service maintains its own state properly.
            }
            
            // Notify delegate *after* orientation is set and digital zoom (if any) is applied
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Determine the LOGICAL lens state based on the final zoom factor
                let finalLens: CameraLens
                if lens == .wide && zoomFactor == CameraLens.x2.zoomFactor {
                    // If we physically switched to wide specifically to apply 2x digital zoom
                    finalLens = .x2
                } else {
                    // Otherwise, the logical lens matches the physical lens we switched to
                    finalLens = lens
                }
                logger.debug("🔄 Lens switch: Notifying delegate about logical lens update: \(finalLens.rawValue)x, physical: \(lens.rawValue)x, final zoom: \(zoomFactor)")
                self.delegate?.didUpdateCurrentLens(finalLens) // Notify with the logical lens
            }
            
            logger.info("✅ Successfully switched to \(lens.rawValue)× lens")
            
        } catch let specificError as CameraError {
            logger.error("❌ Failed to switch lens: \(specificError.description)")
            session.commitConfiguration() // Always commit to end configuration block
            
            // REMOVED: Automatic recovery attempt
            /*
            if lens != .wide {
                logger.info("🔄 Attempting to recover by switching to wide angle")
                switchToLens(.wide)
            } else {
                // If we can't even switch to wide angle, notify delegate of error
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.didEncounterError(.configurationFailed)
                }
            }
            */
           
            // Propagate the specific error
            DispatchQueue.main.async { [weak self] in
                 self?.delegate?.didEncounterError(specificError)
            }
            
            if wasRunning {
                 logger.info("▶️ Attempting to restart session after failed lens switch...")
                 session.startRunning()
             }
        } catch {
             logger.error("❌ Failed to switch lens with unexpected error: \(error.localizedDescription)")
             session.commitConfiguration() // Always commit to end configuration block
             
             // Propagate a generic configuration error for unexpected errors
             DispatchQueue.main.async { [weak self] in
                 self?.delegate?.didEncounterError(.configurationFailed(message: "Lens switch failed: \(error.localizedDescription)"))
             }
             
             if wasRunning {
                 logger.info("▶️ Attempting to restart session after failed lens switch...")
                 session.startRunning()
             }
         }
    }
    
    private func setDigitalZoom(to factor: CGFloat, on device: AVCaptureDevice) {
        logger.info("📸 Setting digital zoom INSTANTLY to \(factor)×") // Indicate instant change
        
        do {
            try device.lockForConfiguration()
            
            let zoomFactorClamped = factor.clamped(to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor)
            // Set instantly instead of ramping for button presses
            device.videoZoomFactor = zoomFactorClamped
            
            device.unlockForConfiguration()
            
            // Keep delegate notification here
            DispatchQueue.main.async { [weak self] in
                // Notify actual applied factor (might differ slightly if clamped)
                self?.delegate?.didUpdateZoomFactor(factor)
                // Notify that the logical lens is now 2x if the factor matches
                if factor == CameraLens.x2.zoomFactor {
                     self?.delegate?.didUpdateCurrentLens(.x2)
                     self?.logger.debug("📸 Digital zoom set, notifying delegate that logical lens is now .x2")
                }
            }
            
            logger.info("✅ Set digital zoom instantly to \(factor)× (Applied: \(zoomFactorClamped))")
            
        } catch {
            logger.error("❌ Failed to set zoom: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didEncounterError(.configurationFailed)
            }
        }
    }
    
    func setZoomFactor(_ factor: CGFloat, currentLens: CameraLens, availableLenses: [CameraLens]) {
        guard let currentDevice = self.device else {
            logger.error("No camera device available for zoom factor adjustment.")
            return
        }
        
        // Find the appropriate lens based on the zoom factor
        // Use a small tolerance to prefer staying on the current lens if very close
        let tolerance = 0.05
        let targetLens = availableLenses
            .sorted { lens1, lens2 in
                let diff1 = abs(lens1.zoomFactor - factor)
                let diff2 = abs(lens2.zoomFactor - factor)
                // Prioritize current lens within tolerance
                if lens1 == currentLens && diff1 <= tolerance { return true }
                if lens2 == currentLens && diff2 <= tolerance { return false }
                // Otherwise, pick the closest
                return diff1 < diff2
            }
            .first ?? .wide

        logger.debug("Slider zoom: Target factor=\(factor), Current=\(currentLens.rawValue)x, Target Lens=\(targetLens.rawValue)x")

        // If we need to switch lenses (and not just slightly off due to tolerance)
        if targetLens != currentLens {
            logger.debug("Slider zoom: Switching lens from \(currentLens.rawValue)x to \(targetLens.rawValue)x")
            // Lens switch triggered by slider should be instant too now
            switchToLens(targetLens)
            // After switching, we might need to apply remaining zoom smoothly
            // Let the delegate update handle the state, then a subsequent call to this function might apply ramp
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in // Small delay to allow lens switch state update
                 self?.setZoomFactor(factor, currentLens: targetLens, availableLenses: availableLenses)
             }
            return
        }
        
        // If staying on the same lens, apply zoom smoothly using RAMP
        do {
            try currentDevice.lockForConfiguration()
            
            // Calculate zoom factor relative to the current lens's base zoom
            let baseZoom = currentLens.zoomFactor // e.g., 1.0 for wide, 5.0 for telephoto
            let relativeZoom = factor / baseZoom  // Target factor relative to the current physical lens
            
            let zoomFactorClamped = relativeZoom.clamped(to: currentDevice.minAvailableVideoZoomFactor...currentDevice.maxAvailableVideoZoomFactor)
            
            logger.debug("Slider zoom: Staying on \(currentLens.rawValue)x. Ramping to relative factor \(zoomFactorClamped) (Target: \(factor)")
            
            // Use ramp for smooth slider adjustments ON THE SAME LENS
            currentDevice.ramp(toVideoZoomFactor: zoomFactorClamped, withRate: 30.0) // Increased rate for faster slider response

            // Update the overall zoom factor in the delegate immediately
            // Use the unclamped target factor for UI consistency
            self.delegate?.didUpdateZoomFactor(factor)
            // self.lastZoomFactor = zoomFactorClamped // Keep track of the actual device zoom

            currentDevice.unlockForConfiguration()
        } catch {
            logger.error("Failed to set zoom smoothly via slider: \(error.localizedDescription)")
            self.delegate?.didEncounterError(.configurationFailed)
        }
    }
    
    func optimizeVideoSettings() {
        guard let device = self.device else {
            logger.error("No camera device available")
            return
        }
        
        do {
            try device.lockForConfiguration()
            
            if device.activeFormat.isVideoStabilizationModeSupported(.cinematic) {
                if let connection = self.session.outputs.first?.connection(with: .video),
                   connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .cinematic
                }
            }
            
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            
            device.unlockForConfiguration()
        } catch {
            logger.error("Error optimizing video settings: \(error.localizedDescription)")
        }
    }
    
    // New public method to trigger reconfiguration
    func reconfigureSessionForCurrentDevice() async throws {
        logger.info("🔄 [reconfigureSessionForCurrentDevice] Starting reconfiguration request...")
        guard let currentDevice = self.device else {
            logger.error("❌ [reconfigureSessionForCurrentDevice] Failed: No current device set.")
            throw CameraError.configurationFailed(message: "No current device to reconfigure.")
        }
        
        let wasRunning = session.isRunning
        logger.debug("Session was running: \(wasRunning)")
        if wasRunning {
            logger.info("⏸️ Stopping session for reconfiguration...")
            session.stopRunning()
            // Optional small delay after stopping
            try? await Task.sleep(for: .milliseconds(50))
        }
        
        logger.info("⚙️ Beginning session configuration block...")
        session.beginConfiguration()
        
        do {
            // We don't need to remove/re-add the input if we're just changing format/settings on the *same* device.
            // But we do need to call the configuration logic for the current device.
            logger.info("🔧 Calling internal configureSession logic for device: \(currentDevice.localizedName)")
            
            // Determine the actual lens enum case corresponding to the current physical device
            let currentActualLens = CameraLens.allCases.first { $0.deviceType == currentDevice.deviceType } ?? .wide
            logger.info("🔧 Determined current physical lens for reconfiguration: \(currentActualLens.rawValue)x")
            
            try configureSession(for: currentDevice, lens: currentActualLens) // Pass the determined actual lens
            
            logger.info("⚙️ Committing session configuration block.")
            session.commitConfiguration()

            // Reapply video stabilization setting after reconfiguration
            if let videoDataOutput = session.outputs.first(where: { $0 is AVCaptureVideoDataOutput }) as? AVCaptureVideoDataOutput,
               let connection = videoDataOutput.connection(with: .video),
               connection.isVideoStabilizationSupported {
                let isEnabled = delegate?.isVideoStabilizationCurrentlyEnabled ?? false
                let mode: AVCaptureVideoStabilizationMode = isEnabled ? .standard : .off
                if connection.preferredVideoStabilizationMode != mode {
                    connection.preferredVideoStabilizationMode = mode
                    logger.info("✅ Reconfiguration: Applied video stabilization mode: \(mode.rawValue)")
                } else {
                    logger.info("ℹ️ Reconfiguration: Video stabilization mode already \(mode.rawValue)")
                }
            }

            if wasRunning {
                logger.info("▶️ Restarting session after reconfiguration...")
                session.startRunning()
            }
            logger.info("✅ [reconfigureSessionForCurrentDevice] Reconfiguration completed successfully.")
        } catch {
            logger.error("❌ [reconfigureSessionForCurrentDevice] Error during reconfiguration: \(error.localizedDescription)")
            // Rollback configuration changes on error
            logger.warning("⏪ Rolling back configuration changes due to error.")
            session.commitConfiguration() // Commit to end the block, even though changes failed
            // Try to restart session if it was running before failure
            if wasRunning { 
                logger.info("▶️ Attempting to restart session after failed reconfiguration...")
                session.startRunning()
             }
            throw error // Re-throw the error
        }
    }

    // MARK: - Focus & Exposure

    /// Sets the focus point of interest on the current device.
    /// - Parameters:
    ///   - point: The point of interest in **device coordinate space** (0-1, 0-1).
    ///   - lock: If `true`, locks focus after setting; otherwise uses continuous mode.
    ///   - Note: Exposure point is no longer set by this method (push to exposure removed).
    func setFocusAndExposure(at point: CGPoint, lock: Bool) {
        print("📍 [CameraDeviceService.setFocusAndExposure] Called with point: \(point), lock: \(lock)")
        guard let device = self.device else {
            logger.error("[Focus] No camera device available for focus POI")
            return
        }
        print("📍 [CameraDeviceService.setFocusAndExposure] Current device: \(device.localizedName)")

        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try device.lockForConfiguration()
                print("📍 [CameraDeviceService.setFocusAndExposure] Device locked for configuration")

                if device.isFocusPointOfInterestSupported {
                    // Convert the point for portrait orientation
                    let rotatedPoint = CGPoint(x: point.y, y: 1.0 - point.x)
                    print("📍 [CameraDeviceService.setFocusAndExposure] Original point: \(point), Rotated point: \(rotatedPoint)")
                    
                    // Always set the focus point first
                    device.focusPointOfInterest = rotatedPoint
                    
                    if lock {
                        // Two-step focus lock process
                        if device.isFocusModeSupported(.autoFocus) {
                            print("📍 [CameraDeviceService.setFocusAndExposure] Step 1: Setting focus mode to .autoFocus to grab focus")
                            device.focusMode = .autoFocus
                            
                            // Wait for focus to complete before locking
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                                guard let self = self else { return }
                                do {
                                    try device.lockForConfiguration()
                                    if device.isFocusModeSupported(.locked) {
                                        print("📍 [CameraDeviceService.setFocusAndExposure] Step 2: Locking focus after auto-focus completed")
                                        device.focusMode = .locked
                                    }
                                    device.unlockForConfiguration()
                                } catch {
                                    self.logger.error("[Focus] Failed to lock focus after auto-focus: \(error.localizedDescription)")
                                }
                            }
                        }
                    } else {
                        // For regular tap, ensure we switch to continuous auto-focus
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            print("📍 [CameraDeviceService.setFocusAndExposure] Setting focus mode to .continuousAutoFocus")
                            // First use auto-focus to grab initial focus at the point
                            if device.isFocusModeSupported(.autoFocus) {
                                device.focusMode = .autoFocus
                                
                                // Then switch to continuous after a brief moment
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                                    guard let self = self else { return }
                                    do {
                                        try device.lockForConfiguration()
                                        device.focusMode = .continuousAutoFocus
                                        device.unlockForConfiguration()
                                    } catch {
                                        self.logger.error("[Focus] Failed to switch to continuous auto-focus: \(error.localizedDescription)")
                                    }
                                }
                            } else {
                                // If .autoFocus not supported, go directly to continuous
                                device.focusMode = .continuousAutoFocus
                            }
                        }
                    }
                } else {
                    print("📍 [CameraDeviceService.setFocusAndExposure] Focus POI not supported on device")
                }

                device.unlockForConfiguration()
                print("📍 [CameraDeviceService.setFocusAndExposure] Device configuration unlocked")

                // Notify delegate that focus lock state changed if needed
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if lock {
                        print("📍 [CameraDeviceService.setFocusAndExposure] Notifying delegate of focus lock state change")
                        self.delegate?.didUpdateCurrentLens(self.currentDeviceLens())
                    }
                }

            } catch {
                self.logger.error("[Focus] Failed to set focus: \(error.localizedDescription)")
                print("❌ [CameraDeviceService.setFocusAndExposure] Error setting focus: \(error.localizedDescription)")
            }
        }
    }

    /// Helper to find current lens from device type
    private func currentDeviceLens() -> CameraLens {
        guard let device = self.device else { return .wide }
        if let match = CameraLens.allCases.first(where: { $0.deviceType == device.deviceType }) {
            return match
        }
        return .wide
    }

    // Helper method to trigger memory cleanup
    private func triggerMemoryCleanup() {
        // Trigger low memory warning to force cleanup
        logger.debug("Triggering memory cleanup...")
        
        // Add any explicit cleanup code here
        // This could include removing references to large objects, 
        // clearing caches, or releasing any resources that might be held
        
        // Flush and purge any caches
        URLCache.shared.removeAllCachedResponses()
        
        // If we have access to the CameraViewModel, we can trigger cleanup there too
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("TriggerMemoryCleanup"), object: nil)
        }
    }
}
