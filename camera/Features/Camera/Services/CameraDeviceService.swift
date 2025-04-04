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
        
        // If Apple Log is enabled, try to find and set a compatible format first
        if videoFormatService.appleLogEnabled {
            logger.info("🍏 Apple Log enabled, searching for compatible format on \(newDevice.localizedName)")
            let appleLogFormats = newDevice.formats.filter { $0.supportedColorSpaces.contains(.appleLog) }
            
            if let compatibleFormat = appleLogFormats.first {
                 // Ideally, match resolution/FPS here, but for now, just find *any* compatible format
                if newDevice.activeFormat != compatibleFormat {
                    newDevice.activeFormat = compatibleFormat
                    logger.info("✅ Set Apple Log compatible format: \(compatibleFormat.description)")
                } else {
                    logger.info("ℹ️ Current format already supports Apple Log.")
                }
            } else {
                logger.warning("⚠️ Apple Log enabled, but no compatible format found on \(newDevice.localizedName). Apple Log will not be applied.")
            }
        }
        
        // Set other default configurations
        if newDevice.isExposureModeSupported(.continuousAutoExposure) {
            newDevice.exposureMode = .continuousAutoExposure
        }
        if newDevice.isFocusModeSupported(.continuousAutoFocus) {
            newDevice.focusMode = .continuousAutoFocus
        }
        newDevice.unlockForConfiguration()
        
        logger.info("✅ Successfully configured session for \(newDevice.localizedName)")
    }
    
    func switchToLens(_ lens: CameraLens) {
        // Capture the interface orientation on the main thread before dispatching
        let currentInterfaceOrientation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation ?? .portrait

        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            
            // For 2x zoom, use digital zoom on the wide angle camera
            if lens == .x2 {
                if let currentDevice = self.device,
                   currentDevice.deviceType == .builtInWideAngleCamera {
                    self.setDigitalZoom(to: lens.zoomFactor, on: currentDevice)
                } else {
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
            
            // Re-apply color space settings within the same configuration transaction
            try videoFormatService.reapplyColorSpaceSettings(for: newDevice)
            logger.debug("🔄 Lens switch: Re-applied color space settings.")
            
            logger.debug("🔄 Lens switch: Committing configuration...")
            session.commitConfiguration()
            logger.debug("🔄 Lens switch: Configuration committed.")
            
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
    
    // Helper method to update connections after switching lenses
    func updateVideoOrientation(for connection: AVCaptureConnection, orientation: UIInterfaceOrientation) {
        // Log the current state
        logger.debug("📱 Orientation Update Request Start:")
        logger.debug("- Interface Orientation: \(orientation.rawValue)")
        logger.debug("- Device Orientation: \(UIDevice.current.orientation.rawValue) (isValid: \(UIDevice.current.orientation.isValidInterfaceOrientation))")
        logger.debug("- Connection: \(connection.description)")
        logger.debug("- Current Connection Angle: \(connection.videoRotationAngle)°")
        
        let newAngle: CGFloat
        let deviceOrientation = UIDevice.current.orientation
        var source: String // Log the source of the orientation decision
        
        // First check device orientation for more accurate rotation
        if deviceOrientation.isValidInterfaceOrientation {
            source = "Device Orientation (\(deviceOrientation.rawValue))"
            switch deviceOrientation {
            case .portrait:
                newAngle = 90  // Portrait mode: rotate 90° clockwise
            case .landscapeLeft:  // USB port on right
                newAngle = 0   // No rotation needed
            case .landscapeRight:  // USB port on left
                newAngle = 180 // Rotate 180°
            case .portraitUpsideDown:
                newAngle = 270
            default:
                // Should not happen due to isValidInterfaceOrientation check, but handle defensively
                source = "Interface Orientation (Fallback from Device: \(orientation.rawValue))"
                switch orientation {
                case .portrait: newAngle = 90
                case .landscapeLeft: newAngle = 0
                case .landscapeRight: newAngle = 180
                case .portraitUpsideDown: newAngle = 270
                default: newAngle = 90 // Default to portrait
                }
            }
        } else {
            // Fallback to interface orientation if device orientation is not valid
            source = "Interface Orientation (Device Invalid: \(orientation.rawValue))"
            switch orientation {
            case .portrait:
                newAngle = 90
            case .landscapeLeft:
                newAngle = 0
            case .landscapeRight:
                newAngle = 180
            case .portraitUpsideDown:
                newAngle = 270
            default:
                logger.warning("Unknown orientation, defaulting to portrait (90°)")
                newAngle = 90
            }
        }
        
        logger.debug("📱 Determined angle \(newAngle)° based on: \(source)")
        
        // Check if the new angle is supported
        guard connection.isVideoRotationAngleSupported(newAngle) else {
            logger.warning("Rotation angle \(newAngle)° not supported for connection: \(connection.description)")
            return
        }
        
        // Only update if the angle is actually different
        if connection.videoRotationAngle != newAngle {
            connection.videoRotationAngle = newAngle
            logger.info("Updated video connection \(connection.description) rotation angle to \(newAngle)° (Source: \(source))")
        } else {
            logger.debug("📱 Angle \(newAngle)° already set for connection \(connection.description). No change needed.")
        }
        logger.debug("📱 Orientation Update Request End.")
    }
}
