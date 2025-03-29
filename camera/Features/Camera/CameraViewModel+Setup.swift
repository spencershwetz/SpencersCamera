import AVFoundation
import Photos
import UIKit
import os.log

// MARK: - Setup and Initialization
extension CameraViewModel {
    
    func setupSession() throws {
        print("DEBUG: 🎥 Setting up camera session")
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.beginConfiguration()
        
        // Get available lenses
        availableLenses = CameraLens.availableLenses()
        print("DEBUG: 📸 Available lenses: \(availableLenses.map { $0.rawValue }.joined(separator: ", "))")
        
        // Start with wide angle camera
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .back) else {
            print("DEBUG: ❌ No camera device available")
            error = .cameraUnavailable
            status = .failed
            session.commitConfiguration()
            return
        }
        
        print("DEBUG: ✅ Found camera device: \(videoDevice.localizedName)")
        self.device = videoDevice
        
        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            self.videoDeviceInput = input
            
            // Always try to set up Apple Log format initially
            if let appleLogFormat = findBestAppleLogFormat(videoDevice) {
                let frameRateRange = appleLogFormat.videoSupportedFrameRateRanges.first!
                try videoDevice.lockForConfiguration()
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.maxFrameRate))
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(frameRateRange.minFrameRate))
                videoDevice.activeFormat = appleLogFormat
                videoDevice.activeColorSpace = .appleLog
                print("Initial setup: Enabled Apple Log in 4K ProRes format")
                videoDevice.unlockForConfiguration()
            } else {
                print("Initial setup: Apple Log format not available")
                isAppleLogEnabled = false
            }
            
            if session.canAddInput(input) {
                session.addInput(input)
                print("DEBUG: ✅ Added video input to session")
            } else {
                print("DEBUG: ❌ Failed to add video input to session")
            }
            
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
                print("DEBUG: ✅ Added audio input to session")
            }
            
            // Add video data output for AVAssetWriter
            let videoDataOutput = AVCaptureVideoDataOutput()
            videoDataOutput.setSampleBufferDelegate(self, queue: processingQueue)
            
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
                print("DEBUG: ✅ Added video data output to session")
                
                // Configure initial video settings
                updateVideoConfiguration()
            } else {
                print("DEBUG: ❌ Failed to add video data output to session")
            }
            
            if let device = device {
                try device.lockForConfiguration()
                let duration = CMTimeMake(value: 1000, timescale: Int32(selectedFrameRate * 1000))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                print("DEBUG: ✅ Set frame rate to \(selectedFrameRate) fps")
            }
            
        } catch {
            print("Error setting up camera: \(error)")
            self.error = .setupFailed
            session.commitConfiguration()
            return
        }
        
        session.commitConfiguration()
        print("DEBUG: ✅ Session configuration committed")
        
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
            print("DEBUG: ✅ Using 4K preset")
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
            print("DEBUG: ✅ Using 1080p preset")
        }
        
        // Request camera permissions if needed
        checkCameraPermissionsAndStart()
        
        isAppleLogSupported = device?.formats.contains { format in
            format.supportedColorSpaces.contains(.appleLog)
        } ?? false
        
        defaultFormat = device?.activeFormat
    }
    
    func checkCameraPermissionsAndStart() {
        let cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch cameraAuthorizationStatus {
        case .authorized:
            print("DEBUG: ✅ Camera access already authorized")
            startCameraSession()
            
        case .notDetermined:
            print("DEBUG: 🔄 Requesting camera authorization...")
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    print("DEBUG: ✅ Camera access granted")
                    self.startCameraSession()
                } else {
                    print("DEBUG: ❌ Camera access denied")
                    DispatchQueue.main.async {
                        self.error = .unauthorized
                        self.status = .unauthorized
                    }
                }
            }
            
        case .denied, .restricted:
            print("DEBUG: ❌ Camera access denied or restricted")
            DispatchQueue.main.async {
                self.error = .unauthorized
                self.status = .unauthorized
            }
            
        @unknown default:
            print("DEBUG: ❓ Unknown camera authorization status")
            startCameraSession()
        }
    }
    
    func startCameraSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            print("DEBUG: 🎬 Starting camera session...")
            if !self.session.isRunning {
                self.session.startRunning()
                
                DispatchQueue.main.async {
                    self.isSessionRunning = self.session.isRunning
                    self.status = self.session.isRunning ? .running : .failed
                    print("DEBUG: 📷 Camera session running: \(self.session.isRunning)")
                }
            } else {
                print("DEBUG: ⚠️ Camera session already running")
                
                DispatchQueue.main.async {
                    self.isSessionRunning = true
                    self.status = .running
                }
            }
        }
    }
} 