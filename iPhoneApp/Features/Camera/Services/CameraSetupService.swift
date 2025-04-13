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
    private var videoDataOutput: AVCaptureVideoDataOutput?
    
    let videoDataOutputCoordinator = VideoDataOutputCoordinator()
    
    init(session: AVCaptureSession, delegate: CameraSetupServiceDelegate) {
        self.session = session
        self.delegate = delegate
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
        
        // --- Add Video Data Output ---
        let videoOutput = AVCaptureVideoDataOutput()
        // Recommended settings for real-time processing
        videoOutput.alwaysDiscardsLateVideoFrames = true 
        // Specify pixel format. BGRA is common for previews, but YUV might be needed for efficient recording/processing depending on requirements.
        // Let's start with BGRA as MetalPreviewView expects it initially.
        // We might need to adapt MetalPreviewView/MetalFrameProcessor later if we switch to YUV here.
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(videoDataOutputCoordinator, queue: videoDataOutputCoordinator.delegateQueue)
            self.videoDataOutput = videoOutput // Store reference
            logger.info("Added shared video data output and set coordinator as delegate.")
            
            // Ensure connection orientation is correct (Portrait)
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                    logger.info("Set shared video output connection rotation angle to 90°")
                } else {
                    logger.warning("Shared video output connection does not support rotation angle 90°")
                }
            } else {
                logger.warning("Could not get connection for shared video output.")
            }
        } else {
            logger.error("Could not add shared video data output to session.")
            // Handle error appropriately, maybe throw or delegate
        }
        // --- End Add Video Data Output ---

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
            
            self.logger.info("Attempting to start camera session on background thread...")
            if !self.session.isRunning {
                self.logger.info("Session is not running. Calling startRunning() now.")
                
                var didStartSuccessfully = false
                do {
                    self.session.startRunning()
                    didStartSuccessfully = true // Assume success if no immediate exception
                    self.logger.info("startRunning() called. Checking session state...")
                } catch {
                    // Although startRunning() doesn't officially throw, capture potential unexpected issues.
                    self.logger.error("Caught unexpected error during startRunning(): \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.delegate?.didEncounterError(.setupFailed)
                        self.delegate?.didUpdateSessionStatus(.failed)
                    }
                    return // Exit if there was an immediate error
                }
                
                // Check the state *after* calling startRunning
                let isRunningAfterStart = self.session.isRunning
                self.logger.info("Session isRunning property after startRunning() call: \(isRunningAfterStart)")

                // Ensure the video output connection orientation is still correct after session starts
                if let connection = self.videoDataOutput?.connection(with: .video), connection.videoRotationAngle != 90 {
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                        self.logger.info("Re-applied 90° rotation to shared video output connection after session start.")
                    }
                }

                DispatchQueue.main.async {
                    self.delegate?.didStartRunning(isRunningAfterStart)
                    self.delegate?.didUpdateSessionStatus(isRunningAfterStart ? .running : .failed)
                    self.logger.info("Notified delegate on main thread. Final running state: \(isRunningAfterStart)")
                }
            } else {
                self.logger.warning("Camera session was already running when startCameraSession() was called.")
                
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
    
    // Helper to get the shared video output (needed by RecordingService)
    func getVideoOutput() -> AVCaptureVideoDataOutput? {
        return self.videoDataOutput
    }
} 