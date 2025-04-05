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
        // Remove existing inputs and outputs
        session.inputs.forEach { session.removeInput($0) }
        
        // Add new input
        let newInput = try AVCaptureDeviceInput(device: newDevice)
        guard session.canAddInput(newInput) else {
            logger.error("❌ Cannot add input for \(newDevice.localizedName)")
            throw CameraError.invalidDeviceInput
        }
        
        session.addInput(newInput)
        videoDeviceInput = newInput
        device = newDevice
        
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
            
            // *** Add code to set data output orientation AFTER committing config ***
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
            // *** End added code ***
            
            if wasRunning {
                logger.debug("🔄 Lens switch: Starting session...")
                session.startRunning()
                logger.debug("🔄 Lens switch: Session started.")
            }
            
            // Notify delegate *after* orientation is set
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                logger.debug("🔄 Lens switch: Notifying delegate about lens update: \(lens.rawValue)x")
                self.delegate?.didUpdateCurrentLens(lens)
                self.delegate?.didUpdateZoomFactor(zoomFactor)
            }
            
            logger.info("✅ Successfully switched to \(lens.rawValue)× lens")
            
        } catch {
            logger.error("❌ Failed to switch lens: \(error.localizedDescription)")
            session.commitConfiguration()
            
            // Try to recover by returning to wide angle
            if lens != .wide {
                logger.info("🔄 Attempting to recover by switching to wide angle")
                switchToLens(.wide)
            } else {
                // If we can't even switch to wide angle, notify delegate of error
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.didEncounterError(.configurationFailed)
                }
            }
            
            if wasRunning {
                session.startRunning()
            }
        }
    }
    
    private func setDigitalZoom(to factor: CGFloat, on device: AVCaptureDevice) {
        logger.info("📸 Setting digital zoom to \(factor)×")
        
        do {
            try device.lockForConfiguration()
            
            let zoomFactor = factor.clamped(to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor)
            device.ramp(toVideoZoomFactor: zoomFactor, withRate: 20.0)
            
            device.unlockForConfiguration()
            
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didUpdateZoomFactor(factor)
            }
            
            logger.info("✅ Set digital zoom to \(factor)×")
            
        } catch {
            logger.error("❌ Failed to set zoom: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didEncounterError(.configurationFailed)
            }
        }
    }
    
    func setZoomFactor(_ factor: CGFloat, currentLens: CameraLens, availableLenses: [CameraLens]) {
        guard let currentDevice = self.device else {
            logger.error("No camera device available")
            return
        }
        
        // Find the appropriate lens based on the zoom factor
        let targetLens = availableLenses
            .sorted { abs($0.zoomFactor - factor) < abs($1.zoomFactor - factor) }
            .first ?? .wide
        
        // If we need to switch lenses
        if targetLens != currentLens && abs(targetLens.zoomFactor - factor) < 0.5 {
            switchToLens(targetLens)
            return
        }
        
        do {
            try currentDevice.lockForConfiguration()
            
            // Calculate zoom factor relative to the current lens
            let baseZoom = currentLens.zoomFactor
            let relativeZoom = factor / baseZoom
            let zoomFactor = min(max(relativeZoom, currentDevice.minAvailableVideoZoomFactor),
                               currentDevice.maxAvailableVideoZoomFactor)
            
            // Apply zoom smoothly
            currentDevice.ramp(toVideoZoomFactor: zoomFactor, withRate: 20.0)
            
            self.delegate?.didUpdateZoomFactor(factor)
            self.lastZoomFactor = zoomFactor
            
            currentDevice.unlockForConfiguration()
        } catch {
            logger.error("Failed to set zoom: \(error.localizedDescription)")
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
            try configureSession(for: currentDevice, lens: .wide) // We need a lens, but it's less critical here if device is same
            // TODO: Revisit if passing .wide is always correct here, or if we need current lens state.
            
            logger.info("⚙️ Committing session configuration block.")
            session.commitConfiguration()

            // *** Add code to set data output orientation AFTER committing config ***
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
            // *** End added code ***

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
