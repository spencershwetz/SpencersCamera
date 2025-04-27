import AVFoundation
import CoreImage
import UIKit
import os.log

class CameraManager: NSObject {
    static let shared = CameraManager()
    
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var photoOutput: AVCapturePhotoOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraManager")
    
    // Delegate to handle camera output
    weak var delegate: CameraManagerDelegate?
    
    private override init() {
        super.init()
    }
    
    func setupCamera() async throws {
        let session = AVCaptureSession()
        self.captureSession = session
        
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        // Configure for high quality
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        
        // Get camera device
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            logger.error("Failed to get camera device")
            throw CameraError.deviceNotAvailable
        }
        
        // Add camera input
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
                logger.info("Added camera input successfully")
            }
        } catch {
            logger.error("Failed to create camera input: \(error.localizedDescription)")
            throw CameraError.configurationFailed
        }
        
        // Configure video output
        let videoOutput = AVCaptureVideoDataOutput()
        self.videoOutput = videoOutput
        
        // Create a dedicated serial queue for sample buffer handling
        let videoQueue = DispatchQueue(label: "camera.video.queue", qos: .userInteractive)
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        
        // Get available formats and log them
        let availableFormats = videoOutput.availableVideoPixelFormatTypes
        logger.info("Available pixel formats: \(availableFormats)")
        
        // Try to find the best supported format
        var selectedFormat: OSType?
        let preferredFormats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA
        ]
        
        for format in preferredFormats {
            if availableFormats.contains(where: { $0.int32Value == Int32(format) }) {
                selectedFormat = format
                logger.info("Selected pixel format: \(format)")
                break
            }
        }
        
        guard let format = selectedFormat else {
            logger.error("No supported pixel format found")
            throw CameraError.configurationFailed
        }
        
        // Configure video settings with supported format
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(format)
        ]
        
        // Optimize for real-time processing
        videoOutput.alwaysDiscardsLateVideoFrames = true
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            logger.info("Added video output successfully")
            
            // Configure video orientation
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = false
                }
            }
        } else {
            logger.error("Could not add video output to session")
            throw CameraError.configurationFailed
        }
        
        // Configure photo output
        let photoOutput = AVCapturePhotoOutput()
        self.photoOutput = photoOutput
        
        // Enable high resolution capture
        photoOutput.maxPhotoQualityPrioritization = .quality
        
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            logger.info("Added photo output successfully")
        }
        
        // Start session on background thread
        Task.detached { [weak self] in
            self?.captureSession?.startRunning()
            self?.logger.info("Camera session started successfully")
        }
    }
    
    func configurePreview(in view: UIView) {
        guard let session = captureSession else { return }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        self.previewLayer = previewLayer
        
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        
        // Important: Set the optimal pixel format
        previewLayer.connection?.videoColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        
        view.layer.addSublayer(previewLayer)
        logger.info("Preview layer configured successfully")
    }
    
    func updateOrientation() {
        guard let connection = previewLayer?.connection else { return }
        
        let orientation = UIDevice.current.orientation
        let videoOrientation: AVCaptureVideoOrientation
        
        switch orientation {
        case .portrait:
            videoOrientation = .portrait
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        case .landscapeLeft:
            videoOrientation = .landscapeRight
        case .landscapeRight:
            videoOrientation = .landscapeLeft
        default:
            videoOrientation = .portrait
        }
        
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
            logger.info("Updated video orientation to: \(videoOrientation)")
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Lock base address before accessing pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        delegate?.cameraManager(self, didReceiveFrame: pixelBuffer)
    }
}

// MARK: - Protocols & Enums
protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didReceiveFrame pixelBuffer: CVPixelBuffer)
}

enum CameraError: Error {
    case deviceNotAvailable
    case configurationFailed
} 