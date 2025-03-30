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
    
    init(session: AVCaptureSession, delegate: CameraDeviceServiceDelegate) {
        self.session = session
        self.delegate = delegate
    }
    
    func setDevice(_ device: AVCaptureDevice) {
        self.device = device
    }
    
    func setVideoDeviceInput(_ input: AVCaptureDeviceInput) {
        self.videoDeviceInput = input
    }
    
    func switchToLens(_ lens: CameraLens) {
        logger.info("Switching to \(lens.rawValue)× lens")
        
        // For 2x zoom, we use digital zoom on the wide angle camera
        if lens == .x2 {
            guard let currentDevice = device,
                  currentDevice.deviceType == .builtInWideAngleCamera else {
                // Switch to wide angle first if we're not already on it
                switchToLens(.wide)
                return
            }
            
            do {
                try currentDevice.lockForConfiguration()
                currentDevice.ramp(toVideoZoomFactor: lens.zoomFactor, withRate: 20.0)
                currentDevice.unlockForConfiguration()
                delegate?.didUpdateCurrentLens(lens)
                delegate?.didUpdateZoomFactor(lens.zoomFactor)
                logger.info("Set digital zoom to 2x")
            } catch {
                logger.error("Failed to set digital zoom: \(error.localizedDescription)")
                delegate?.didEncounterError(.configurationFailed)
            }
            return
        }
        
        guard let newDevice = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
            logger.error("Failed to get device for \(lens.rawValue)× lens")
            return
        }
        
        session.beginConfiguration()
        
        // Remove existing input
        if let currentInput = videoDeviceInput {
            session.removeInput(currentInput)
        }
        
        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                videoDeviceInput = newInput
                device = newDevice
                delegate?.didUpdateCurrentLens(lens)
                delegate?.didUpdateZoomFactor(lens.zoomFactor)
                
                // Reset zoom factor when switching physical lenses
                try newDevice.lockForConfiguration()
                newDevice.videoZoomFactor = 1.0
                newDevice.unlockForConfiguration()
                
                logger.info("Successfully switched to \(lens.rawValue)× lens")
            } else {
                logger.error("Cannot add input for \(lens.rawValue)× lens")
            }
        } catch {
            logger.error("Error switching to \(lens.rawValue)× lens: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed)
        }
        
        session.commitConfiguration()
    }
    
    func setZoomFactor(_ factor: CGFloat, currentLens: CameraLens, availableLenses: [CameraLens]) {
        guard let currentDevice = device else {
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
            
            delegate?.didUpdateZoomFactor(factor)
            lastZoomFactor = zoomFactor
            
            currentDevice.unlockForConfiguration()
        } catch {
            logger.error("Failed to set zoom: \(error.localizedDescription)")
            delegate?.didEncounterError(.configurationFailed)
        }
    }
    
    func optimizeVideoSettings() {
        guard let device = device else {
            logger.error("No camera device available")
            return
        }
        
        do {
            try device.lockForConfiguration()
            
            if device.activeFormat.isVideoStabilizationModeSupported(.cinematic) {
                if let connection = session.outputs.first?.connection(with: .video),
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
        guard !isRecordingOrientationLocked else {
            logger.info("Orientation update skipped: Recording in progress.")
            return
        }
        
        let newAngle: CGFloat
        
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
        isRecordingOrientationLocked = locked
        logger.info("Orientation updates \(locked ? "locked" : "unlocked") for recording.")
    }
} 