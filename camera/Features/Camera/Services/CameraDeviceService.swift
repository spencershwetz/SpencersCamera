import AVFoundation
import os.log
import UIKit

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
    
    init(session: AVCaptureSession, delegate: CameraDeviceServiceDelegate) {
        self.session = session
        self.delegate = delegate
    }
    
    // New method to get available lenses based on discovery
    func getAvailableCameraLenses() -> [CameraLens] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        )
        
        var availableLenses: [CameraLens] = []
        var hasWide = false
        
        for device in discoverySession.devices {
            if let lens = getCameraLens(for: device) {
                if !availableLenses.contains(lens) { // Avoid duplicates if discovery returns same type multiple times
                    availableLenses.append(lens)
                    if lens == .wide { hasWide = true }
                }
            }
        }
        
        // If wide lens exists, add the .x2 digital zoom option
        if hasWide && !availableLenses.contains(.x2) {
            availableLenses.append(.x2)
        }
        
        // Sort the lenses logically (e.g., ultra-wide, wide, x2, telephoto)
        availableLenses.sort { $0.zoomFactor < $1.zoomFactor }
        
        logger.info("📸 Determined available lenses: \(availableLenses.map { $0.rawValue })")
        return availableLenses
    }

    // New method to map AVCaptureDevice to CameraLens enum
    func getCameraLens(for device: AVCaptureDevice) -> CameraLens? {
        switch device.deviceType {
        case .builtInUltraWideCamera:
            return .ultraWide
        case .builtInWideAngleCamera:
            return .wide
        case .builtInTelephotoCamera:
            // Differentiate telephoto based on zoom factor if necessary in the future
            return .telephoto
        default:
            return nil // Or handle other specific types if needed
        }
    }
    
    func setDevice(_ device: AVCaptureDevice) {
        self.device = device
        logger.info("📸 Set initial device: \(device.localizedName)")
    }
    
    func setVideoDeviceInput(_ input: AVCaptureDeviceInput) {
        self.videoDeviceInput = input
        logger.info("📸 Set initial video input: \(input.device.localizedName)")
    }
    
    private func configureSession(for newDevice: AVCaptureDevice, lens: CameraLens, isAppleLogEnabled: Bool) throws {
        logger.info("⚙️ Configuring session for \(newDevice.localizedName) (\(lens.rawValue)x), User Apple Log Preference: \(isAppleLogEnabled)")
        // Remove existing inputs and outputs (ensure this is safe if outputs are needed for orientation later)
        // Consider if removing outputs here is correct or should happen later. Assuming it's okay for now.
        session.inputs.forEach { session.removeInput($0) }

        // Add new input
        let newInput = try AVCaptureDeviceInput(device: newDevice)
        guard session.canAddInput(newInput) else {
            logger.error("❌ Cannot add input for \(newDevice.localizedName)")
            session.commitConfiguration() // Commit before throwing
            throw CameraError.invalidDeviceInput
        }
        session.addInput(newInput)
        videoDeviceInput = newInput
        device = newDevice // Update the active device reference *after* adding input

        // --- Refactored Color Space Logic ---
        var appliedColorSpace: AVCaptureColorSpace = .sRGB // Default to sRGB
        var appliedFormat: AVCaptureDevice.Format? = newDevice.activeFormat // Start with default active format

        if isAppleLogEnabled {
            logger.info("  🔎 User wants Apple Log. Checking support for \(lens.rawValue)x lens...")
            // Find formats supporting Apple Log (consider resolution/frame rate later if needed)
            // Let's simplify the check first: just look for *any* format supporting Apple Log.
            // We might need a more sophisticated format selection later.
            let appleLogFormats = newDevice.formats.filter { (format: AVCaptureDevice.Format) -> Bool in // Explicit type annotation
                format.supportedColorSpaces.contains(.appleLog)
                // Optional: Add resolution/FPS checks here if necessary
                // let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            }

            if let bestFormat = appleLogFormats.first { // Or choose based on resolution/FPS
                logger.info("    ✅ \(lens.rawValue)x lens supports Apple Log. Found suitable format.")
                appliedFormat = bestFormat
                appliedColorSpace = .appleLog
            } else {
                logger.warning("    ⚠️ \(lens.rawValue)x lens does not support Apple Log or no suitable format found. Reverting to sRGB.")
                // Log available color spaces for debugging
                let allColorSpaces = newDevice.formats.flatMap { $0.supportedColorSpaces }
                let uniqueSpaces = Set(allColorSpaces).map { $0.rawValue }
                logger.info("      Available color spaces for \(newDevice.localizedName): \(uniqueSpaces)")
            }
        } else {
            logger.info("  ℹ️ User has Apple Log disabled. Using sRGB.")
        }

        // Lock device for configuration to set format and color space
        do {
            try newDevice.lockForConfiguration()

            // Set format first (if changed)
            if let formatToSet = appliedFormat, newDevice.activeFormat != formatToSet {
                newDevice.activeFormat = formatToSet
                let dims = CMVideoFormatDescriptionGetDimensions(formatToSet.formatDescription)
                logger.info("  💾 Set activeFormat: \(dims.width)x\(dims.height)")
            } else {
                 logger.info("  💾 Kept existing activeFormat.")
            }


            // Then set color space
            if newDevice.activeColorSpace != appliedColorSpace {
                // Double-check the *chosen format* actually supports the color space (should be guaranteed by logic above)
                 if newDevice.activeFormat.supportedColorSpaces.contains(appliedColorSpace) {
                    newDevice.activeColorSpace = appliedColorSpace
                    let colorSpaceDescription = (appliedColorSpace == .appleLog) ? "Apple Log" : "sRGB"
                    logger.info("  🎨 Set activeColorSpace: \(colorSpaceDescription)")
                 } else {
                     let colorSpaceDesc = appliedColorSpace.rawValue // Get the raw value for logging
                     logger.error("  ❌ Internal Error: Chosen format does not support the target color space (\(colorSpaceDesc)). Falling back to sRGB.")
                     newDevice.activeColorSpace = .sRGB // Fallback safely
                 }
            } else {
                 let colorSpaceDescription = (appliedColorSpace == .appleLog) ? "Apple Log" : "sRGB"
                 logger.info("  🎨 Kept existing activeColorSpace: \(colorSpaceDescription)")
            }

            // Configure other device settings (exposure, focus)
            if newDevice.isExposureModeSupported(.continuousAutoExposure) {
                newDevice.exposureMode = .continuousAutoExposure
            }
            if newDevice.isFocusModeSupported(.continuousAutoFocus) {
                newDevice.focusMode = .continuousAutoFocus
            }

            newDevice.unlockForConfiguration()
            logger.info("  ✅ Device configuration locked and updated.")

        } catch {
            logger.error("❌ Failed to lock device for configuration: \(error.localizedDescription)")
            newDevice.unlockForConfiguration() // Ensure unlock on error
            // Rollback? Commit configuration might happen outside this function.
            // For now, rethrow the error.
             throw error // Rethrow the lock error
        }
         logger.info("✅ Successfully configured session for \(newDevice.localizedName)")

        // Note: Session configuration (begin/commit) and start/stop are handled in the calling function (`switchToLens`)
    }
    
    func switchToLens(
        _ lens: CameraLens,
        currentZoomFactor: CGFloat,
        availableLenses: [CameraLens],
        isAppleLogEnabled: Bool
    ) {
        logger.info("🔄 Attempting to switch lens to: \(lens.rawValue)x")
        
        // CAPTURE orientation on main thread *before* going to background
        let currentInterfaceOrientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .interfaceOrientation ?? .portrait
        
        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            
            // For 2x zoom, use digital zoom on the wide angle camera
            if lens == .x2 {
                if let currentDevice = self.device,
                   currentDevice.deviceType == .builtInWideAngleCamera {
                    self.setDigitalZoom(to: lens.zoomFactor, on: currentDevice, availableLenses: availableLenses)
                } else {
                    // Pass the captured orientation
                    self.switchToPhysicalLens(.wide, thenSetZoomTo: lens.zoomFactor, currentInterfaceOrientation: currentInterfaceOrientation, isAppleLogEnabled: isAppleLogEnabled, availableLenses: availableLenses)
                }
                return
            }
            
            // For all other lenses, try to switch physical device
            // Pass the captured orientation
            self.switchToPhysicalLens(lens, thenSetZoomTo: 1.0, currentInterfaceOrientation: currentInterfaceOrientation, isAppleLogEnabled: isAppleLogEnabled, availableLenses: availableLenses)
        }
    }
    
    // CHANGE: Add currentInterfaceOrientation parameter
    // CHANGE: Add availableLenses parameter
    private func switchToPhysicalLens(_ lens: CameraLens, thenSetZoomTo zoomFactor: CGFloat, currentInterfaceOrientation: UIInterfaceOrientation, isAppleLogEnabled: Bool, availableLenses: [CameraLens]) {
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
            // No need to pass orientation here as we aren't reconfiguring the session
            setDigitalZoom(to: zoomFactor, on: currentDevice, availableLenses: availableLenses)
            return
        }
        
        // --- Orientation Logic --- 
        // Determine the target rotation angle based *only* on the current interface orientation
        // captured *before* this background task started.
        let targetVideoAngle: CGFloat
        switch currentInterfaceOrientation {
            case .portrait: targetVideoAngle = 90
            case .landscapeLeft: targetVideoAngle = 0    // USB right
            case .landscapeRight: targetVideoAngle = 180 // USB left
            case .portraitUpsideDown: targetVideoAngle = 270
            default: targetVideoAngle = 90 // Default to portrait
        }
        logger.info("Target video angle based on captured interface orientation: \(targetVideoAngle)°")
        // --- End Orientation Logic ---
        
        // Configure session with new device
        let wasRunning = session.isRunning
        if wasRunning {
            session.stopRunning()
        }
        
        session.beginConfiguration()
        
        do {
            // Pass the isAppleLogEnabled flag to configureSession
            try configureSession(for: newDevice, lens: lens, isAppleLogEnabled: isAppleLogEnabled)
            
            // Immediately set orientation for all video connections BEFORE committing configuration
            // This ensures we never display frames with incorrect orientation
            for output in session.outputs {
                if let connection = output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(targetVideoAngle) { // Use the calculated targetVideoAngle
                    connection.videoRotationAngle = targetVideoAngle // Apply the correct angle
                    logger.info("Applied initial video angle \(targetVideoAngle)° to connection for output: \(output.description)")
                } else if let connection = output.connection(with: .video) {
                     logger.warning("Video angle \(targetVideoAngle)° not supported for connection: \(connection.description)")
                }
            }
            
            session.commitConfiguration()
            
            if wasRunning {
                session.startRunning()
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.didUpdateCurrentLens(lens)
                self.delegate?.didUpdateZoomFactor(zoomFactor)
            }
            
            logger.info("✅ Successfully switched to \(lens.rawValue)× lens")
            
        } catch {
            logger.error("❌ Failed to switch lens: \(error.localizedDescription)")
            session.commitConfiguration() // Ensure commit even on failure
            
            // Try to recover by returning to wide angle
            if lens != .wide {
                logger.info("🔄 Attempting to recover by switching to wide angle")
                // We need the orientation again for the recovery switch
                DispatchQueue.main.async { [weak self] in // Get orientation on main thread
                    guard let self else { return }
                    // Get orientation again for the recovery switch using modern API
                    let recoveryOrientation = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first?
                        .interfaceOrientation ?? .portrait
                    // Pass availableLenses here too during recovery
                    self.switchToLens(.wide, currentZoomFactor: 1.0, availableLenses: self.getAvailableCameraLenses(), isAppleLogEnabled: false) // Let switchToLens handle dispatching again
                }
            } else {
                // If we can't even switch to wide angle, notify delegate of error
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.didEncounterError(.configurationFailed)
                }
            }
            
            // Restart session if it was running before the attempt
            if wasRunning {
                session.startRunning()
            }
        }
    }
    
    private func setDigitalZoom(to factor: CGFloat, on device: AVCaptureDevice, availableLenses: [CameraLens]) {
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
    
    func setZoomFactor(_ factor: CGFloat, currentLens: CameraLens, availableLenses: [CameraLens], isAppleLogEnabled: Bool) {
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
            // Pass the received isAppleLogEnabled state
            switchToLens(targetLens, currentZoomFactor: factor, availableLenses: availableLenses, isAppleLogEnabled: isAppleLogEnabled)
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
    
    // Helper method to update connections after switching lenses
    func updateVideoOrientation(for connection: AVCaptureConnection, orientation: UIInterfaceOrientation) {
        // Log the current state
        logger.info("📱 Orientation Update Request:")
        logger.info("- Interface Orientation: \(orientation.rawValue)")
        logger.info("- Device Orientation: \(UIDevice.current.orientation.rawValue)")
        logger.info("- Current Connection Angle: \(connection.videoRotationAngle)°")
        logger.info("- Recording Lock State: \(self.isRecordingOrientationLocked)")
        
        guard !self.isRecordingOrientationLocked else {
            logger.info("Orientation update skipped: Recording in progress.")
            return
        }
        
        let newAngle: CGFloat
        let deviceOrientation = UIDevice.current.orientation
        
        // First check device orientation for more accurate rotation
        if deviceOrientation.isValidInterfaceOrientation {
            switch deviceOrientation {
            case .portrait:
                newAngle = 90  // Portrait mode: rotate 90° clockwise
                logger.info("Setting portrait orientation from device (90°)")
            case .landscapeLeft:  // USB port on right
                newAngle = 0   // No rotation needed
                logger.info("Setting landscape left from device - USB right (0°)")
            case .landscapeRight:  // USB port on left
                newAngle = 180 // Rotate 180°
                logger.info("Setting landscape right from device - USB left (180°)")
            case .portraitUpsideDown:
                newAngle = 270
                logger.info("Setting portrait upside down from device (270°)")
            default:
                // Fallback to interface orientation
                switch orientation {
                case .portrait:
                    newAngle = 90
                    logger.info("Setting portrait orientation from interface (90°)")
                case .landscapeLeft:
                    newAngle = 0
                    logger.info("Setting landscape left from interface - USB right (0°)")
                case .landscapeRight:
                    newAngle = 180
                    logger.info("Setting landscape right from interface - USB left (180°)")
                case .portraitUpsideDown:
                    newAngle = 270
                    logger.info("Setting portrait upside down from interface (270°)")
                default:
                    logger.warning("Unknown orientation, defaulting to portrait (90°)")
                    newAngle = 90
                }
            }
        } else {
            // Fallback to interface orientation if device orientation is not valid
            switch orientation {
            case .portrait:
                newAngle = 90
                logger.info("Setting portrait orientation from interface (90°)")
            case .landscapeLeft:
                newAngle = 0
                logger.info("Setting landscape left from interface - USB right (0°)")
            case .landscapeRight:
                newAngle = 180
                logger.info("Setting landscape right from interface - USB left (180°)")
            case .portraitUpsideDown:
                newAngle = 270
                logger.info("Setting portrait upside down from interface (270°)")
            default:
                logger.warning("Unknown orientation, defaulting to portrait (90°)")
                newAngle = 90
            }
        }
        
        // Check if the new angle is supported
        guard connection.isVideoRotationAngleSupported(newAngle) else {
            logger.warning("Rotation angle \(newAngle)° not supported for connection.")
            return
        }
        
        // Only update if the angle is actually different
        if connection.videoRotationAngle != newAngle {
            connection.videoRotationAngle = newAngle
            logger.info("Updated video connection rotation angle to \(newAngle)°")
        }
    }
    
    // Flag to track orientation locking during recording
    private var isRecordingOrientationLocked = false
    
    func lockOrientationForRecording(_ locked: Bool) {
        self.isRecordingOrientationLocked = locked
        logger.info("Orientation updates \(locked ? "locked" : "unlocked") for recording.")
        if locked {
            logger.info("📱 Locking orientation state:")
            logger.info("- Interface Orientation: \(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation.rawValue ?? -1)")
            logger.info("- Device Orientation: \(UIDevice.current.orientation.rawValue)")
            if let connection = session.outputs.first?.connection(with: .video) {
                logger.info("- Current Connection Angle: \(connection.videoRotationAngle)°")
            }
        }
    }
}
