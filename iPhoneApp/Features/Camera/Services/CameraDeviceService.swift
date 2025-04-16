import AVFoundation
import os.log
import UIKit
import Foundation

protocol CameraDeviceServiceDelegate: AnyObject {
    func didUpdateCurrentLens(_ lens: CameraLens)
    func didUpdateZoomFactor(_ factor: CGFloat)
    func didEncounterError(_ error: CameraError)
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
    
    // Public computed property to access the current device
    var currentDevice: AVCaptureDevice? {
        return device
    }
    
    init(session: AVCaptureSession, videoFormatService: VideoFormatService, delegate: CameraDeviceServiceDelegate) {
        self.session = session
        self.videoFormatService = videoFormatService
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
        do {
            let frameDuration = self.videoFormatService.getFrameDuration(for: currentFPS)
            if newDevice.activeVideoMinFrameDuration != frameDuration || newDevice.activeVideoMaxFrameDuration != frameDuration {
                newDevice.activeVideoMinFrameDuration = frameDuration
                newDevice.activeVideoMaxFrameDuration = frameDuration
                logger.info("✅ [configureSession] Applied specific frame duration lock for \(currentFPS) FPS.")
            } else {
                logger.info("ℹ️ [configureSession] Device already locked to the correct frame duration for \(currentFPS) FPS.")
            }
        } catch {
            logger.warning("⚠️ [configureSession] Could not get or apply frame duration lock: \(error.localizedDescription)")
            // Potentially throw here if strict frame rate is essential?
        }
        // ---> END Added Code <---
        
        // Set other default configurations like exposure/focus (if needed here)
        if newDevice.isExposureModeSupported(.continuousAutoExposure) {
            newDevice.exposureMode = .continuousAutoExposure
        }
        if newDevice.isFocusModeSupported(.continuousAutoFocus) {
            newDevice.focusMode = .continuousAutoFocus
        }
        // Note: Frame rate and color space are handled by VideoFormatService during its calls
        // or by the reapplyColorSpaceSettings call after this.
        
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
            
            // Re-apply color space settings after switching format
            try videoFormatService.reapplyColorSpaceSettings()
            logger.info("🔄 Lens switch: Re-applied color space settings.")
            
            logger.debug("🔄 Lens switch: Committing configuration...")
            session.commitConfiguration()
            logger.debug("🔄 Lens switch: Configuration committed.")
            
            // *** REMOVE code setting data output orientation here ***
            /*
            if let videoDataOutput = session.outputs.first(where: { $0 is AVCaptureVideoDataOutput }) as? AVCaptureVideoDataOutput,
               let connection = videoDataOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                    logger.info("🔄 Lens switch: Set VideoDataOutput connection angle to 90° after config commit.")
                } else {
                    logger.warning("🔄 Lens switch: 90° angle not supported for VideoDataOutput after config commit.")
                }
            } else {
                logger.warning("🔄 Lens switch: Could not find VideoDataOutput or connection after config commit.")
            }
            */
            logger.info("🔄 Lens switch: Skipping explicit VideoDataOutput connection angle setting.") // Add log indicating skip
            // *** End removal ***
            
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

            // *** REMOVE code setting data output orientation here ***
            /*
            if let videoDataOutput = session.outputs.first(where: { $0 is AVCaptureVideoDataOutput }) as? AVCaptureVideoDataOutput,
               let connection = videoDataOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                    logger.info("🔄 [reconfigureSessionForCurrentDevice] Set VideoDataOutput connection angle to 90° after config commit.")
                } else {
                    logger.warning("🔄 [reconfigureSessionForCurrentDevice] 90° angle not supported for VideoDataOutput after config commit.")
                }
            } else {
                logger.warning("🔄 [reconfigureSessionForCurrentDevice] Could not find VideoDataOutput or connection after config commit.")
            }
            */
            logger.info("🔄 [reconfigureSessionForCurrentDevice] Skipping explicit VideoDataOutput connection angle setting.") // Add log indicating skip
            // *** End removal ***

            // Re-apply color space just in case (redundant if called by ViewModel, but safe)
            logger.info("🎨 Re-applying color space settings after reconfiguration...")
            try videoFormatService.reapplyColorSpaceSettings()
            
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
}
