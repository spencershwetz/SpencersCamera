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
    }
}

extension Notification.Name {
    static let appleLogSettingChanged = Notification.Name("appleLogSettingChanged")
} 