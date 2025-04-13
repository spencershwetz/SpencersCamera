import Foundation
import AVFoundation
import CoreMedia

class SettingsModel: ObservableObject {
    @Published var isAppleLogEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAppleLogEnabled, forKey: "isAppleLogEnabled")
            NotificationCenter.default.post(name: .appleLogSettingChanged, object: nil)
        }
    }
    
    @Published var isFlashlightEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isFlashlightEnabled, forKey: "isFlashlightEnabled")
            NotificationCenter.default.post(name: .flashlightSettingChanged, object: nil)
        }
    }
    
    @Published var flashlightIntensity: Float {
        didSet {
            UserDefaults.standard.set(flashlightIntensity, forKey: "flashlightIntensity")
            NotificationCenter.default.post(name: .flashlightSettingChanged, object: nil)
        }
    }
    
    @Published var isBakeInLUTEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isBakeInLUTEnabled, forKey: "isBakeInLUTEnabled")
            NotificationCenter.default.post(name: .bakeInLUTSettingChanged, object: nil)
        }
    }
    
    var isAppleLogSupported: Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return false
        }
        
        // Check if any format supports Apple Log
        return device.formats.contains { format in
            let colorSpaces = format.supportedColorSpaces.map { $0.rawValue }
            return colorSpaces.contains(AVCaptureColorSpace.appleLog.rawValue)
        }
    }
    
    init() {
        // 1. Read all initial values from UserDefaults
        let initialAppleLogEnabled = UserDefaults.standard.bool(forKey: "isAppleLogEnabled")
        let initialFlashlightEnabled = UserDefaults.standard.bool(forKey: "isFlashlightEnabled")
        let initialFlashlightIntensity = UserDefaults.standard.float(forKey: "flashlightIntensity")
        let bakeInLUTValue = UserDefaults.standard.object(forKey: "isBakeInLUTEnabled")

        // 2. Determine final initial values, applying defaults
        var finalFlashlightIntensity = initialFlashlightIntensity
        var shouldWriteFlashlightDefault = false
        if initialFlashlightIntensity == 0 { // Check the local constant, not self
            finalFlashlightIntensity = 1.0
            shouldWriteFlashlightDefault = true
        }

        var finalBakeInLUTEnabled: Bool
        var shouldWriteBakeInLUTDefault = false
        if bakeInLUTValue == nil {
            finalBakeInLUTEnabled = false // Default to OFF
            shouldWriteBakeInLUTDefault = true
        } else {
            // If a value exists, use it (reading directly again is fine)
            finalBakeInLUTEnabled = UserDefaults.standard.bool(forKey: "isBakeInLUTEnabled")
        }
        
        // 3. Initialize all @Published properties
        self.isAppleLogEnabled = initialAppleLogEnabled
        self.isFlashlightEnabled = initialFlashlightEnabled
        self.flashlightIntensity = finalFlashlightIntensity
        self.isBakeInLUTEnabled = finalBakeInLUTEnabled
        
        // 4. Write back defaults if they were applied
        if shouldWriteFlashlightDefault {
            UserDefaults.standard.set(finalFlashlightIntensity, forKey: "flashlightIntensity")
        }
        if shouldWriteBakeInLUTDefault {
            UserDefaults.standard.set(finalBakeInLUTEnabled, forKey: "isBakeInLUTEnabled")
        }
    }
}

extension Notification.Name {
    static let appleLogSettingChanged = Notification.Name("appleLogSettingChanged")
    static let flashlightSettingChanged = Notification.Name("flashlightSettingChanged")
    static let bakeInLUTSettingChanged = Notification.Name("bakeInLUTSettingChanged")
} 