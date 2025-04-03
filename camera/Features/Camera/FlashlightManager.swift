import AVFoundation
import Foundation

class FlashlightManager: ObservableObject {
    @Published private(set) var isAvailable: Bool = false
    @Published var isEnabled: Bool = false {
        didSet {
            if oldValue != isEnabled {
                setTorchState()
            }
        }
    }
    @Published var intensity: Float = 1.0 {
        didSet {
            if isEnabled {
                setTorchState()
            }
        }
    }
    
    private var device: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }
    
    init() {
        checkAvailability()
    }
    
    private func checkAvailability() {
        guard let device = device else {
            isAvailable = false
            return
        }
        isAvailable = device.hasTorch && device.isTorchAvailable
    }
    
    private func setTorchState() {
        guard let device = device,
              device.hasTorch,
              device.isTorchAvailable else {
            return
        }
        
        do {
            try device.lockForConfiguration()
            
            if isEnabled {
                // Clamp intensity to a minimum of 0.001 (0.1%) for ultra-low light
                let clampedIntensity = max(0.001, min(1.0, intensity))
                
                // Configure torch with intensity
                try device.setTorchModeOn(level: clampedIntensity)
            } else {
                device.torchMode = .off
            }
            
            device.unlockForConfiguration()
        } catch {
            print("Error setting torch state: \(error.localizedDescription)")
        }
    }
    
    func performStartupSequence() async {
        // Store the user's preferred intensity
        let userIntensity = intensity
        
        // Set directly to normal recording state with user's preferred intensity
        await MainActor.run {
            self.intensity = userIntensity
            self.isEnabled = true
            // Log the action
            print("🔦 FlashlightManager: Enabled directly for recording start.")
        }
    }
    
    func cleanup() {
        isEnabled = false
        // Log the action
        print("🔦 FlashlightManager: Cleanup called. Flashlight turned off.")
    }
    
    func turnOffForSettingsExit() {
        isEnabled = false
    }
} 