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
    private var previewVideoOutput: AVCaptureVideoDataOutput?
    
    var currentVideoDeviceInput: AVCaptureDeviceInput? {
        return videoDeviceInput
    }
    
    init(session: AVCaptureSession, delegate: CameraSetupServiceDelegate) {
        self.session = session
        self.delegate = delegate
    }
    
    func setupSession() throws -> AVCaptureVideoDataOutput? {
        logger.info("Setting up camera session")
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.beginConfiguration()
        
        defer { session.commitConfiguration() }
        
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .back) else {
            logger.error("No camera device available")
            delegate?.didEncounterError(.cameraUnavailable)
            delegate?.didUpdateSessionStatus(.failed)
            return nil
        }
        
        logger.info("Found camera device: \(videoDevice.localizedName)")
        
        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            videoDeviceInput = input
            
            if session.canAddInput(input) {
                session.addInput(input)
                logger.info("Added video input to session")
            } else {
                logger.error("Failed to add video input to session")
                throw CameraError.setupFailed
            }
            
            delegate?.didInitializeCamera(device: videoDevice)
            
        } catch {
            logger.error("Error setting up video input: \(error.localizedDescription)")
            delegate?.didEncounterError(.setupFailed)
            throw error
        }
        
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            logger.info("Added audio input to session")
        } else {
             logger.warning("Could not add audio input to session.")
        }
        
        let previewOutput = AVCaptureVideoDataOutput()
        previewOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        previewOutput.alwaysDiscardsLateVideoFrames = true
        
        if session.canAddOutput(previewOutput) {
            session.addOutput(previewOutput)
            self.previewVideoOutput = previewOutput
            logger.info("Added PREVIEW video data output to session.")
        } else {
            logger.error("Could not add PREVIEW video data output to session.")
            delegate?.didEncounterError(.setupFailed)
            return nil
        }
        
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
            logger.info("Using 4K preset")
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
            logger.info("Using 1080p preset")
        }
        
        checkCameraPermissionsAndStart()
        
        return previewVideoOutput
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
                self.session.startRunning()
                
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