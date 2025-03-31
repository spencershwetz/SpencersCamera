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
        
        // Check if format supports Apple Log before switching
        if let currentDevice = device,
           currentDevice.activeColorSpace == .appleLog {
            // Find a format that supports Apple Log for the new device
            let formats = newDevice.formats.filter { format in
                let desc = format.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
                let resolution = dimensions.width >= 1920 && dimensions.height >= 1080
                
                // Log format capabilities for debugging
                if hasAppleLog {
                    logger.info("Found format with Apple Log support: \(dimensions.width)x\(dimensions.height)")
                    logger.info("Color spaces: \(format.supportedColorSpaces)")
                }
                
                return hasAppleLog && resolution
            }
            
            // Sort formats by resolution to get the highest quality one
            let sortedFormats = formats.sorted { (format1: AVCaptureDevice.Format, format2: AVCaptureDevice.Format) -> Bool in
                let dim1 = CMVideoFormatDescriptionGetDimensions(format1.formatDescription)
                let dim2 = CMVideoFormatDescriptionGetDimensions(format2.formatDescription)
                return dim1.width * dim1.height > dim2.width * dim2.height
            }
            
            if let appleLogFormat = sortedFormats.first {
                try newDevice.lockForConfiguration()
                newDevice.activeFormat = appleLogFormat
                
                // Ensure format supports Apple Log before setting
                if appleLogFormat.supportedColorSpaces.contains(.appleLog) {
                    newDevice.activeColorSpace = .appleLog
                    logger.info("✅ Successfully configured Apple Log for \(lens.rawValue) lens")
                    let dimensions = CMVideoFormatDescriptionGetDimensions(appleLogFormat.formatDescription)
                    logger.info("Selected format: \(dimensions.width)x\(dimensions.height)")
                } else {
                    logger.warning("⚠️ Selected format does not support Apple Log")
                    newDevice.activeColorSpace = .sRGB
                }
                
                newDevice.unlockForConfiguration()
            } else {
                logger.warning("⚠️ No suitable Apple Log format found for \(lens.rawValue) lens")
                logger.info("Available formats: \(newDevice.formats.count)")
                // Log the first few formats for debugging
                newDevice.formats.prefix(3).forEach { format in
                    let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    logger.info("Format: \(dim.width)x\(dim.height), Color spaces: \(format.supportedColorSpaces)")
                }
            }
        }
        
        session.addInput(newInput)
        videoDeviceInput = newInput
        device = newDevice
        
        // Configure the new device
        try newDevice.lockForConfiguration()
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
        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            
            // For 2x zoom, use digital zoom on the wide angle camera
            if lens == .x2 {
                if let currentDevice = self.device,
                   currentDevice.deviceType == .builtInWideAngleCamera {
                    self.setDigitalZoom(to: lens.zoomFactor, on: currentDevice)
                } else {
                    self.switchToPhysicalLens(.wide, thenSetZoomTo: lens.zoomFactor)
                }
                return
            }
            
            // For all other lenses, try to switch physical device
            self.switchToPhysicalLens(lens, thenSetZoomTo: 1.0)
        }
    }
    
    private func switchToPhysicalLens(_ lens: CameraLens, thenSetZoomTo zoomFactor: CGFloat) {
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
            setDigitalZoom(to: zoomFactor, on: currentDevice)
            return
        }
        
        // Store current orientation settings to preserve during lens switch
        let currentInterfaceOrientation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation ?? .portrait
        var currentVideoAngle: CGFloat = 90 // Default to portrait
        
        // Get current video orientation from any existing connection
        if let videoConnection = session.outputs.first?.connection(with: .video) {
            currentVideoAngle = videoConnection.videoRotationAngle
        }
        
        // Configure session with new device
        let wasRunning = session.isRunning
        if wasRunning {
            session.stopRunning()
        }
        
        session.beginConfiguration()
        
        do {
            try configureSession(for: newDevice, lens: lens)
            
            // Immediately set orientation for all video connections BEFORE committing configuration
            // This ensures we never display frames with incorrect orientation
            for output in session.outputs {
                if let connection = output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(currentVideoAngle) {
                    connection.videoRotationAngle = currentVideoAngle
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
            logger.info("- Interface Orientation: \(UIApplication.shared.windows.first?.windowScene?.interfaceOrientation.rawValue ?? -1)")
            logger.info("- Device Orientation: \(UIDevice.current.orientation.rawValue)")
            if let connection = session.outputs.first?.connection(with: .video) {
                logger.info("- Current Connection Angle: \(connection.videoRotationAngle)°")
            }
        }
    }
}
