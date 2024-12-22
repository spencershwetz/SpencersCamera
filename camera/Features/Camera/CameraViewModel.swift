import AVFoundation
import SwiftUI
import Photos

class CameraViewModel: NSObject, ObservableObject {
    @Published var isSessionRunning = false
    @Published var error: CameraError?
    @Published var whiteBalance: Float = 5000 // Kelvin
    @Published var iso: Float = 100
    @Published var shutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 60) // 1/60
    @Published var isRecording = false
    @Published var recordingFinished = false
    @Published var isProcessingRecording = false
    
    let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var output: AVCaptureMovieFileOutput?
    
    var minISO: Float {
        device?.activeFormat.minISO ?? 50
    }
    
    var maxISO: Float {
        device?.activeFormat.maxISO ?? 1600
    }
    
    override init() {
        super.init()
        setupSession()
    }
    
    func setupSession() {
        print("Setting up camera session...")
        print("Current session running state: \(session.isRunning)")
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("Failed to get camera device")
            error = .deviceNotFound
            return
        }
        
        self.device = device
        
        do {
            session.beginConfiguration()
            
            try device.lockForConfiguration()
            
            // Set the format for full resolution
            if let format = device.formats.first(where: { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dimensions.width == 1920 && dimensions.height == 1080 // 1080p
            }) {
                device.activeFormat = format
                print("Set camera format to: \(format)")
            }
            
            // Reset zoom to 1x
            device.videoZoomFactor = device.minAvailableVideoZoomFactor
            
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if device.isExposureModeSupported(.custom) {
                device.exposureMode = .custom
            }
            device.unlockForConfiguration()
            
            let input = try AVCaptureDeviceInput(device: device)
            print("Created camera input")
            
            if session.canAddInput(input) {
                session.addInput(input)
                print("Added camera input to session")
            }
            
            let audioDevice = AVCaptureDevice.default(for: .audio)
            if let audioDevice = audioDevice,
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
                print("Added audio input to session")
            }
            
            let output = AVCaptureMovieFileOutput()
            self.output = output
            
            if session.canAddOutput(output) {
                session.addOutput(output)
                print("Added video output to session")
            }
            
            session.commitConfiguration()
            
            // Start session on a background thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                print("Starting camera session...")
                self?.session.startRunning()
                print("Session running state after start: \(self?.session.isRunning ?? false)")
                
                DispatchQueue.main.async {
                    print("Camera session started")
                    self?.isSessionRunning = true
                }
            }
            
        } catch {
            print("Camera setup failed with error: \(error)")
            self.error = .setupFailed
        }
    }
    
    func updateWhiteBalance(_ temperature: Float) {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            
            // Get the temperature and tint values
            let temperatureAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: temperature,
                tint: 0.0
            )
            
            // Get the gains
            var gains = device.deviceWhiteBalanceGains(for: temperatureAndTint)
            
            // Ensure gains are within valid range
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(gains.redGain, maxGain)
            gains.greenGain = min(gains.greenGain, maxGain)
            gains.blueGain = min(gains.blueGain, maxGain)
            
            // Ensure gains are at least 1.0
            gains.redGain = max(1.0, gains.redGain)
            gains.greenGain = max(1.0, gains.greenGain)
            gains.blueGain = max(1.0, gains.blueGain)
            
            device.setWhiteBalanceModeLocked(with: gains) { _ in }
            device.unlockForConfiguration()
            
            whiteBalance = temperature
        } catch {
            print("White balance error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    func updateISO(_ iso: Float) {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            
            // Ensure ISO is within device's supported range
            let clampedISO = min(max(device.activeFormat.minISO, iso), device.activeFormat.maxISO)
            
            device.setExposureModeCustom(duration: device.exposureDuration, iso: clampedISO) { _ in }
            device.unlockForConfiguration()
            
            self.iso = clampedISO
            
        } catch {
            print("ISO error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    func updateShutterSpeed(_ speed: CMTime) {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: speed, iso: device.iso) { _ in }
            device.unlockForConfiguration()
            
            shutterSpeed = speed
        } catch {
            self.error = .configurationFailed
        }
    }
    
    func startRecording() {
        guard !isRecording && !isProcessingRecording else { 
            print("Cannot start recording: Recording already in progress or processing")
            return 
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoPath = documentsPath.appendingPathComponent("recording-\(Date().timeIntervalSince1970).mov")
        
        print("Starting recording to: \(videoPath)")
        output?.startRecording(to: videoPath, recordingDelegate: self)
        isRecording = true
    }
    
    func stopRecording() {
        guard isRecording else { 
            print("Cannot stop recording: No recording in progress")
            return 
        }
        
        print("Stopping recording")
        isProcessingRecording = true
        output?.stopRecording()
        isRecording = false
    }
}

extension CameraViewModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        defer {
            isProcessingRecording = false
        }
        
        if let error = error {
            DispatchQueue.main.async {
                self.error = .recordingFailed
                print("Recording error: \(error)")
            }
            return
        }
        
        print("Recording finished, saving to photo library")
        // Save to photo library
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    self?.error = .savingFailed
                    print("Photo library access denied")
                }
                return
            }
            
            PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .video, fileURL: outputFileURL, options: options)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        print("Video saved successfully to photo library")
                        self?.recordingFinished = true
                    } else {
                        print("Error saving video: \(String(describing: error))")
                        self?.error = .savingFailed
                    }
                }
            }
        }
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print("Recording started")
    }
} 