import AVFoundation
import SwiftUI
import Photos
import VideoToolbox
import CoreVideo
import os.log
import CoreImage
import CoreMedia
import UIKit

class CameraViewModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    // Add property to track the view containing the camera preview
    weak var owningView: UIView?
    
    // Flashlight manager
    private let flashlightManager = FlashlightManager()
    private var settingsObserver: NSObjectProtocol?
    
    @Published var status: Status = .unknown
    @Published var captureMode: CaptureMode = .video
    
    private let logger = Logger(subsystem: "com.camera", category: "CameraViewModel")
    
    @Published var isSessionRunning = false
    @Published var error: CameraError?
    @Published var whiteBalance: Float = 5000 // Kelvin
    @Published var iso: Float = 100
    @Published var shutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 60)
    @Published var isRecording = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)
            
            // Lock orientation when recording starts, unlock when it ends
            isOrientationLocked = isRecording
            
            // Store original rotation values when recording starts
            if isRecording {
                // Store current orientation values for all connections
                session.connections.forEach { connection in
                    if connection.isVideoRotationAngleSupported(90) {
                        originalRotationValues[connection] = connection.videoRotationAngle
                    }
                }
                // Force portrait orientation for recording
                updateInterfaceOrientation(lockCamera: true)
            } else {
                // Restore original rotation values when recording ends
                originalRotationValues.forEach { connection, angle in
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = angle
                    }
                }
                originalRotationValues.removeAll()
                flashlightManager.cleanup()
            }
            
            // Handle flashlight state based on recording state
            let settings = SettingsModel()
            if isRecording && settings.isFlashlightEnabled {
                Task {
                    await flashlightManager.performStartupSequence()
                }
            }
        }
    }
    @Published var recordingFinished = false
    @Published var isSettingsPresented = false
    @Published var isProcessingRecording = false
    
    // Add thumbnail property
    @Published var lastRecordedVideoThumbnail: UIImage?
    
    // Storage for temporarily disabling LUT preview without losing the filter
    var tempLUTFilter: CIFilter? {
        didSet {
            if tempLUTFilter != nil {
                print("DEBUG: CameraViewModel stored LUT filter temporarily")
            } else if oldValue != nil {
                print("DEBUG: CameraViewModel cleared temporary LUT filter")
            }
        }
    }
    
    @Published var isAppleLogEnabled = true { // Set Apple Log enabled by default
        didSet {
            print("\n=== Apple Log Toggle ===")
            print("🔄 Status: \(status)")
            print("📹 Capture Mode: \(captureMode)")
            print("✅ Attempting to set Apple Log to: \(isAppleLogEnabled)")
            
            guard status == .running, captureMode == .video else {
                print("❌ Cannot configure Apple Log - Status or mode incorrect")
                print("Required: status == .running (is: \(status))")
                print("Required: captureMode == .video (is: \(captureMode))")
                return
            }
            
            Task {
                do {
                    if isAppleLogEnabled {
                        print("🎥 Configuring Apple Log...")
                        try await configureAppleLog()
                    } else {
                        print("↩️ Resetting Apple Log...")
                        try await resetAppleLog()
                    }
                } catch {
                    await MainActor.run {
                        self.error = .configurationFailed
                    }
                    logger.error("Failed to configure Apple Log: \(error.localizedDescription)")
                    print("❌ Apple Log configuration failed: \(error)")
                }
            }
            print("=== End Apple Log Toggle ===\n")
        }
    }
    
    @Published var isAppleLogSupported = false
    
    let session = AVCaptureSession()
    var device: AVCaptureDevice?
    
    // Video recording properties
    var assetWriter: AVAssetWriter?
    var assetWriterInput: AVAssetWriterInput?
    var assetWriterPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    var videoDataOutput: AVCaptureVideoDataOutput?
    var audioDataOutput: AVCaptureAudioDataOutput?
    var currentRecordingURL: URL?
    var recordingStartTime: CMTime?
    
    var defaultFormat: AVCaptureDevice.Format?
    
    var minISO: Float {
        device?.activeFormat.minISO ?? 50
    }
    var maxISO: Float {
        device?.activeFormat.maxISO ?? 1600
    }
    
    @Published var selectedFrameRate: Double = 30.0
    let availableFrameRates: [Double] = [23.976, 24.0, 25.0, 29.97, 30.0]
    
    private var orientationObserver: NSObjectProtocol?
    @Published var currentInterfaceOrientation: UIInterfaceOrientation = .portrait
    
    let processingQueue = DispatchQueue(
        label: "com.camera.processing",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    
    var lastFrameTimestamp: CFAbsoluteTime = 0
    var lastFrameTime: CMTime?
    var frameCount: Int = 0
    var frameRateAccumulator: Double = 0
    var frameRateUpdateInterval: Int = 30
    
    var supportedFrameRateRange: AVFrameRateRange? {
        device?.activeFormat.videoSupportedFrameRateRanges.first
    }
    
    // Resolution settings
    @Published var selectedResolution: Resolution = .uhd {
        didSet {
            Task {
                do {
                    try await updateCameraFormat(for: selectedResolution)
                } catch {
                    print("Error updating camera format: \(error)")
                    self.error = .configurationFailed
                }
            }
        }
    }
    
    // Codec settings
    @Published var selectedCodec: VideoCodec = .hevc { // Set HEVC as default codec
        didSet {
            updateVideoConfiguration()
        }
    }
    
    @Published var currentTint: Double = 0.0 // Range: -150 to +150
    let tintRange = (-150.0...150.0)
    
    var videoDeviceInput: AVCaptureDeviceInput?
    
    @Published var isAutoExposureEnabled: Bool = true {
        didSet {
            updateExposureMode()
        }
    }
    
    @Published var lutManager = LUTManager()
    var ciContext = CIContext()
    
    var orientationMonitorTimer: Timer?
    
    // Temporarily disable the orientation enforcement during recording
    var isOrientationLocked = false
    
    // Save the original rotation values to restore them after recording
    var originalRotationValues: [AVCaptureConnection: CGFloat] = [:]
    
    @Published var currentLens: CameraLens = .wide
    @Published var availableLenses: [CameraLens] = []
    
    @Published var currentZoomFactor: CGFloat = 1.0
    var lastZoomFactor: CGFloat = 1.0
    
    // HEVC Hardware Encoding Properties
    var compressionSession: VTCompressionSession?
    let encoderQueue = DispatchQueue(label: "com.camera.encoder", qos: .userInteractive)
    
    var encoderSpecification: [CFString: Any] {
        [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
    }
    
    // Track frame counts for logging
    var videoFrameCount = 0
    @Published var audioFrameCount: Int = 0
    var successfulVideoFrames = 0
    var failedVideoFrames = 0
    
    var lastKeyFrameTime: CMTime?
    var lastAdjustmentTime: TimeInterval = 0
    
    override init() {
        super.init()
        print("\n=== Camera Initialization ===")
        
        // Add observer for flashlight settings changes
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .flashlightSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let settings = SettingsModel()
            if self.isRecording && settings.isFlashlightEnabled {
                self.flashlightManager.isEnabled = true
                self.flashlightManager.intensity = settings.flashlightIntensity
            } else {
                self.flashlightManager.isEnabled = false
            }
        }
        
        // Start monitoring device orientation
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        // Add observer for orientation changes
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                guard let self = self else { return }
                // Only update video orientation if we're not recording
                if !self.isRecording {
                    self.updateVideoOrientation()
                }
        }
        
        do {
            try setupSession()
            if let device = device {
                print("📊 Device Capabilities:")
                print("- Name: \(device.localizedName)")
                print("- Model ID: \(device.modelID)")
                
                isAppleLogSupported = device.formats.contains { format in
                    format.supportedColorSpaces.contains(.appleLog)
                }
                print("\n✅ Apple Log Support: \(isAppleLogSupported)")
            }
            print("=== End Initialization ===\n")
            
            if let device = device {
                defaultFormat = device.activeFormat
            }
            
            isAppleLogSupported = device?.formats.contains { format in
                format.supportedColorSpaces.contains(.appleLog)
            } ?? false
        } catch {
            self.error = .setupFailed
            print("Failed to setup session: \(error)")
        }
        
        // Start orientation monitoring
        startOrientationMonitoring()
        
        print("📱 LUT Loading: No default LUTs will be loaded")
    }
    
    deinit {
        // Stop monitoring device orientation
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        
        orientationMonitorTimer?.invalidate()
        orientationMonitorTimer = nil
        
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        flashlightManager.cleanup()
    }
} 