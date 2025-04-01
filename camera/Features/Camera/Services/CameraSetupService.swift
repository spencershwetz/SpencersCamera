import AVFoundation
import Foundation
import os.log
import CoreVideo // Needed for pixel format constants

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
    // ADD: Store reference to the object conforming to output delegate protocols
    private weak var captureOutputDelegate: (AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate)?
    private var videoDeviceInput: AVCaptureDeviceInput?
    // ADD: Store the delegate queue
    private var delegateQueue: DispatchQueue?

    // CHANGE: Modify init to accept the delegate and queue
    init(session: AVCaptureSession,
         delegate: CameraSetupServiceDelegate,
         captureOutputDelegate: (AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate),
         delegateQueue: DispatchQueue) {
        self.session = session
        self.delegate = delegate
        self.captureOutputDelegate = captureOutputDelegate
        self.delegateQueue = delegateQueue
    }

    func setupSession() throws {
        logger.info("Setting up camera session")
        session.beginConfiguration()
        defer { session.commitConfiguration() } // Ensure commitConfiguration is always called

        // --- Input Setup (Existing Code) ---
        session.automaticallyConfiguresCaptureDeviceForWideColor = false // Keep this if needed

        // Start with wide angle camera
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .back) else {
            logger.error("No default back wide-angle camera device available")
            delegate?.didEncounterError(.cameraUnavailable)
            delegate?.didUpdateSessionStatus(.failed)
            throw CameraError.cameraUnavailable // Throw error to prevent further setup
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
                throw CameraError.invalidDeviceInput // Throw error
            }

            // Add Audio Input
            if let audioDevice = AVCaptureDevice.default(for: .audio) {
                 do {
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    if session.canAddInput(audioInput) {
                        session.addInput(audioInput)
                        logger.info("Added audio input to session")
                    } else {
                         logger.warning("Could not add audio input to session.")
                    }
                 } catch {
                      logger.warning("Could not create audio device input: \(error.localizedDescription)")
                 }
            } else {
                logger.warning("No default audio device found.")
            }

            delegate?.didInitializeCamera(device: videoDevice)

        } catch {
            logger.error("Error setting up camera inputs: \(error.localizedDescription)")
            delegate?.didEncounterError(.setupFailed)
            delegate?.didUpdateSessionStatus(.failed)
            throw error // Re-throw error
        }
        // --- End Input Setup ---


        // --- Output Setup (NEW) ---
        guard let delegateQueue = self.delegateQueue,
              let captureOutputDelegate = self.captureOutputDelegate else {
            logger.error("Delegate queue or capture output delegate is nil. Cannot setup outputs.")
            throw CameraError.setupFailed // Or a more specific error
        }

        // Video Data Output
        let videoDataOutput = AVCaptureVideoDataOutput()
        // Configure video settings - BGRA is common for Core Image/Metal processing
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true // Recommended for real-time processing
        videoDataOutput.setSampleBufferDelegate(captureOutputDelegate, queue: delegateQueue)

        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            // Ensure connection uses video stabilization if available and desired
            if let connection = videoDataOutput.connection(with: .video) {
                 if connection.isVideoStabilizationSupported {
                      connection.preferredVideoStabilizationMode = .auto // Or .cinematic if preferred and supported
                      logger.info("Enabled video stabilization on video data output connection.")
                 }
                 // Set initial orientation (optional, CameraDeviceService might handle this later)
                 // connection.videoOrientation = .portrait
            }
            logger.info("Added video data output to session")
        } else {
            logger.error("Failed to add video data output to session")
            throw CameraError.configurationFailed // Throw error
        }

        // Audio Data Output
        let audioDataOutput = AVCaptureAudioDataOutput()
        audioDataOutput.setSampleBufferDelegate(captureOutputDelegate, queue: delegateQueue)

        if session.canAddOutput(audioDataOutput) {
            session.addOutput(audioDataOutput)
            logger.info("Added audio data output to session")
        } else {
            logger.error("Failed to add audio data output to session")
            // This might be less critical than video, decide if it's a fatal error
            // throw CameraError.configurationFailed
        }
        // --- End Output Setup ---


        // --- Session Preset (Existing Code) ---
        // Set preset *after* adding outputs, as some outputs might constrain available presets
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
            logger.info("Using 4K preset")
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
            logger.info("Using 1080p preset")
        } else {
             logger.warning("Could not set desired session preset. Using default.")
        }
        // --- End Session Preset ---

        // Request camera permissions if needed
        checkCameraPermissionsAndStart() // Keep this at the end before returning
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
