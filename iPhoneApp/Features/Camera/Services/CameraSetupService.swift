import AVFoundation
import Foundation
import os.log

protocol CameraSetupServiceDelegate: AnyObject {
    func didUpdateSessionStatus(_ status: CameraViewModel.Status)
    func didEncounterError(_ error: CameraError)
    func didInitializeCamera(device: AVCaptureDevice)
    func didStartRunning(_ isRunning: Bool)
}

class CameraSetupService {
    private let logger = Logger(subsystem: "com.camera", category: "CameraSetupService")
    private var session: AVCaptureSession
    private weak var delegate: CameraSetupServiceDelegate?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var exposureService: ExposureService
    private weak var viewModelDelegate: CameraViewModel?
    
    init(session: AVCaptureSession, exposureService: ExposureService, delegate: CameraSetupServiceDelegate, viewModel: CameraViewModel) {
        self.session = session
        self.exposureService = exposureService
        self.delegate = delegate
        self.viewModelDelegate = viewModel
    }
    
    func setupSession() throws {
        logger.info("Setting up camera session")
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.beginConfiguration()
        
        // Start with wide angle camera
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .back) else {
            logger.error("No camera device available")
            delegate?.didEncounterError(.cameraUnavailable)
            delegate?.didUpdateSessionStatus(.failed)
            session.commitConfiguration()
            return
        }
        
        logger.info("Found camera device: \(videoDevice.localizedName)")
        
        // Configure device within session configuration block
        do {
            try videoDevice.lockForConfiguration()
            
            // Reset all exposure settings first
            if videoDevice.isExposureModeSupported(.locked) {
                videoDevice.exposureMode = .locked
                logger.info("Reset: Set exposure mode to locked first")
            }
            
            // Configure white balance mode
            if videoDevice.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                videoDevice.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            // Configure focus mode
            if videoDevice.isFocusModeSupported(.continuousAutoFocus) {
                videoDevice.focusMode = .continuousAutoFocus
            }
            
            // Finally set exposure mode to auto
            if videoDevice.isExposureModeSupported(.continuousAutoExposure) {
                videoDevice.exposureMode = .continuousAutoExposure
                logger.info("Initial configuration: Set exposure mode to continuousAutoExposure")
            }
            
            videoDevice.unlockForConfiguration()
        } catch {
            logger.error("Failed to configure device: \(error.localizedDescription)")
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            videoDeviceInput = input
            
            if session.canAddInput(input) {
                session.addInput(input)
                logger.info("Added video input to session")
            } else {
                logger.error("Failed to add video input to session")
            }
            
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
                logger.info("Added audio input to session")
            }
            
            delegate?.didInitializeCamera(device: videoDevice)
            
        } catch {
            logger.error("Error setting up camera: \(error.localizedDescription)")
            delegate?.didEncounterError(.setupFailed)
            session.commitConfiguration()
            return
        }
        
        logger.info("Setting up video data output via ViewModel delegate...")
        let _ = print("DEBUG_DEVICE: CameraSetupService calling setupUnifiedVideoOutput on delegate: \(viewModelDelegate != nil ? "VALID" : "NIL")")
        viewModelDelegate?.setupUnifiedVideoOutput()
        
        // Commit configuration after all settings are applied
        session.commitConfiguration()
        
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
            logger.info("Using 4K preset")
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
            logger.info("Using 1080p preset")
        }
        
        // Request camera permissions if needed
        checkCameraPermissionsAndStart()
    }
    
    private func checkCameraPermissionsAndStart() {
        let cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch cameraAuthorizationStatus {
        case .authorized:
            logger.info("Camera access already authorized")
            startCameraSession()
            
        case .notDetermined:
            logger.info("Requesting camera authorization...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self = self else { return }
                
                if granted {
                    self.logger.info("Camera access granted")
                    self.startCameraSession()
                } else {
                    self.logger.error("Camera access denied")
                    DispatchQueue.main.async {
                        self.delegate?.didEncounterError(.unauthorized)
                        self.delegate?.didUpdateSessionStatus(.unauthorized)
                    }
                }
            }
            
        case .denied, .restricted:
            logger.error("Camera access denied or restricted")
            DispatchQueue.main.async {
                self.delegate?.didEncounterError(.unauthorized)
                self.delegate?.didUpdateSessionStatus(.unauthorized)
            }
            
        @unknown default:
            logger.warning("Unknown camera authorization status")
            startCameraSession()
        }
    }
    
    private func startCameraSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            self.logger.info("Starting camera session...")
            if !self.session.isRunning {
                // Begin a new configuration before starting
                self.session.beginConfiguration()
                
                // Ensure device is still in auto mode before starting
                if let device = self.videoDeviceInput?.device {
                    do {
                        try device.lockForConfiguration()
                        if device.exposureMode != .continuousAutoExposure && device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                            self.logger.info("Pre-start: Reconfirmed exposure mode to continuousAutoExposure")
                        }
                        device.unlockForConfiguration()
                    } catch {
                        self.logger.error("Pre-start: Failed to reconfirm exposure mode: \(error.localizedDescription)")
                    }
                }
                
                // Commit configuration before starting
                self.session.commitConfiguration()
                
                // Start the session
                self.session.startRunning()
                
                // Wait for session to stabilize
                Thread.sleep(forTimeInterval: 0.2)
                
                // Verify final state
                if let device = self.videoDeviceInput?.device {
                    let finalMode = device.exposureMode
                    self.logger.info("Final Device Exposure Mode: \(finalMode.rawValue) (0:Locked, 1:Auto, 2:ContinuousAuto, 3:Custom)")
                    
                    // Update exposure service state
                    DispatchQueue.main.async {
                        self.exposureService.setAutoExposureEnabled(finalMode == .continuousAutoExposure)
                    }
                }
                
                DispatchQueue.main.async {
                    let isRunning = self.session.isRunning
                    self.delegate?.didStartRunning(isRunning)
                    self.delegate?.didUpdateSessionStatus(isRunning ? .running : .failed)
                    self.logger.info("Camera session running: \(isRunning)")
                }
            } else {
                self.logger.warning("Camera session already running")
                
                DispatchQueue.main.async {
                    self.delegate?.didStartRunning(true)
                    self.delegate?.didUpdateSessionStatus(.running)
                }
            }
        }
    }
    
    func stopSession() {
        if session.isRunning {
            session.stopRunning()
            delegate?.didStartRunning(false)
        }
    }
} 