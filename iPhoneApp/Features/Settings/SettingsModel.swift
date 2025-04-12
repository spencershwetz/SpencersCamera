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
        self.isAppleLogEnabled = UserDefaults.standard.bool(forKey: "isAppleLogEnabled")
        self.isFlashlightEnabled = UserDefaults.standard.bool(forKey: "isFlashlightEnabled")
        self.flashlightIntensity = UserDefaults.standard.float(forKey: "flashlightIntensity")
        self.isBakeInLUTEnabled = false
        
        // Set default values if not set
        if self.flashlightIntensity == 0 {
            self.flashlightIntensity = 1.0
            UserDefaults.standard.set(self.flashlightIntensity, forKey: "flashlightIntensity")
        }
    }
}

extension Notification.Name {
    static let appleLogSettingChanged = Notification.Name("appleLogSettingChanged")
    static let flashlightSettingChanged = Notification.Name("flashlightSettingChanged")
    static let bakeInLUTSettingChanged = Notification.Name("bakeInLUTSettingChanged")
} 