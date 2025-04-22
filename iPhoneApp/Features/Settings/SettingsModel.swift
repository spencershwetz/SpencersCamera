import Foundation
import AVFoundation
import CoreMedia
import SwiftUI
import Combine

// MARK: - Notification Names
extension Notification.Name {
    static let appleLogSettingChanged = Notification.Name("appleLogSettingChanged")
    static let flashlightSettingChanged = Notification.Name("flashlightSettingChanged")
    static let bakeInLUTSettingChanged = Notification.Name("bakeInLUTSettingChanged")
    static let whiteBalanceLockSettingChanged = Notification.Name("whiteBalanceLockSettingChanged")
    static let exposureLockDuringRecordingSettingChanged = Notification.Name("exposureLockDuringRecordingSettingChanged")
    // Add notifications for function button changes if needed later
}

class SettingsModel: ObservableObject {
    // MARK: - Existing Settings
    @Published var isFlashlightEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isFlashlightEnabled, forKey: Keys.isFlashlightEnabled)
            NotificationCenter.default.post(name: .flashlightSettingChanged, object: nil)
            print("Flashlight Enabled: \(isFlashlightEnabled)")
        }
    }
    
    @Published var flashlightIntensity: Float {
        didSet {
            UserDefaults.standard.set(flashlightIntensity, forKey: Keys.flashlightIntensity)
            NotificationCenter.default.post(name: .flashlightSettingChanged, object: nil)
            print("Flashlight Intensity: \(flashlightIntensity)")
        }
    }
    
    @Published var isBakeInLUTEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isBakeInLUTEnabled, forKey: Keys.isBakeInLUTEnabled)
            NotificationCenter.default.post(name: .bakeInLUTSettingChanged, object: nil)
            print("Bake In LUT Enabled: \(isBakeInLUTEnabled)")
        }
    }
    
    @Published var isExposureLockEnabledDuringRecording: Bool {
        didSet {
            UserDefaults.standard.set(isExposureLockEnabledDuringRecording, forKey: Keys.isExposureLockEnabledDuringRecording)
            NotificationCenter.default.post(name: .exposureLockDuringRecordingSettingChanged, object: nil)
            print("Exposure Lock During Recording Enabled: \(isExposureLockEnabledDuringRecording)")
        }
    }
    
    @Published var isWhiteBalanceLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isWhiteBalanceLockEnabled, forKey: Keys.isWhiteBalanceLockEnabled)
            NotificationCenter.default.post(name: .whiteBalanceLockSettingChanged, object: nil)
        }
    }
    
    // MARK: - Function Button Assignments
    @Published var functionButton1Ability: FunctionButtonAbility {
        didSet {
            UserDefaults.standard.set(functionButton1Ability.rawValue, forKey: Keys.functionButton1Ability)
            print("Function Button 1 Ability: \(functionButton1Ability.rawValue)")
        }
    }
    
    @Published var functionButton2Ability: FunctionButtonAbility {
        didSet {
            UserDefaults.standard.set(functionButton2Ability.rawValue, forKey: Keys.functionButton2Ability)
            print("Function Button 2 Ability: \(functionButton2Ability.rawValue)")
        }
    }

    // MARK: - Computed Properties
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
    
    // MARK: - Persistent Settings
    @AppStorage(Keys.selectedResolutionRaw) var selectedResolutionRaw: String = "3840x2160"
    @AppStorage(Keys.selectedCodecRaw) var selectedCodecRaw: String = "hevc"
    @AppStorage(Keys.selectedFrameRate) var selectedFrameRate: Double = 30.0
    @AppStorage(Keys.isDebugEnabled) var isDebugEnabled: Bool = false
    @AppStorage(Keys.showGrid) var showGrid: Bool = false
    @AppStorage(Keys.selectedLUTURLString) var selectedLUTURLString: String?
    
    @Published var isAppleLogEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAppleLogEnabled, forKey: Keys.isAppleLogEnabled)
            NotificationCenter.default.post(name: .appleLogSettingChanged, object: nil)
            print("Apple Log Enabled: \(isAppleLogEnabled)")
        }
    }
    
    // MARK: - Initialization
    init() {
        // 1. Read all initial values from UserDefaults
        let initialFlashlightEnabled = UserDefaults.standard.bool(forKey: Keys.isFlashlightEnabled)
        let initialFlashlightIntensity = UserDefaults.standard.float(forKey: Keys.flashlightIntensity)
        let bakeInLUTValue = UserDefaults.standard.object(forKey: Keys.isBakeInLUTEnabled)
        let rawFn1Ability = UserDefaults.standard.string(forKey: Keys.functionButton1Ability)
        let rawFn2Ability = UserDefaults.standard.string(forKey: Keys.functionButton2Ability)
        let initialWhiteBalanceLockEnabled = UserDefaults.standard.bool(forKey: Keys.isWhiteBalanceLockEnabled)
        let initialExposureLockEnabledDuringRecording = UserDefaults.standard.bool(forKey: Keys.isExposureLockEnabledDuringRecording)

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
            finalBakeInLUTEnabled = UserDefaults.standard.bool(forKey: Keys.isBakeInLUTEnabled)
        }
        
        let finalFn1Ability = FunctionButtonAbility(rawValue: rawFn1Ability ?? "") ?? .none
        let finalFn2Ability = FunctionButtonAbility(rawValue: rawFn2Ability ?? "") ?? .none

        // 3. Initialize all @Published properties
        self.isFlashlightEnabled = initialFlashlightEnabled
        self.flashlightIntensity = finalFlashlightIntensity
        self.isBakeInLUTEnabled = finalBakeInLUTEnabled
        self.functionButton1Ability = finalFn1Ability
        self.functionButton2Ability = finalFn2Ability
        self.isWhiteBalanceLockEnabled = initialWhiteBalanceLockEnabled
        self.isExposureLockEnabledDuringRecording = initialExposureLockEnabledDuringRecording
        self.isAppleLogEnabled = UserDefaults.standard.bool(forKey: Keys.isAppleLogEnabled)

        // 4. Write back defaults if they were applied
        if shouldWriteFlashlightDefault {
            UserDefaults.standard.set(finalFlashlightIntensity, forKey: Keys.flashlightIntensity)
        }
        if shouldWriteBakeInLUTDefault {
            UserDefaults.standard.set(finalBakeInLUTEnabled, forKey: Keys.isBakeInLUTEnabled)
        }
        // Write function button defaults if they were not set
        if rawFn1Ability == nil {
            UserDefaults.standard.set(finalFn1Ability.rawValue, forKey: Keys.functionButton1Ability)
        }
         if rawFn2Ability == nil {
            UserDefaults.standard.set(finalFn2Ability.rawValue, forKey: Keys.functionButton2Ability)
        }

        print("SettingsModel initialized:")
        print("- Flashlight: \(isFlashlightEnabled)")
        print("- Flashlight Intensity: \(flashlightIntensity)")
        print("- Bake LUT: \(isBakeInLUTEnabled)")
        print("- Lock Exposure During Recording: \(isExposureLockEnabledDuringRecording)")
        print("- Fn1: \(functionButton1Ability.rawValue)")
        print("- Fn2: \(functionButton2Ability.rawValue)")
    }
    
    // MARK: - Keys for UserDefaults
    private enum Keys {
        static let isAppleLogEnabled = "isAppleLogEnabled"
        static let isFlashlightEnabled = "isFlashlightEnabled"
        static let flashlightIntensity = "flashlightIntensity"
        static let isBakeInLUTEnabled = "isBakeInLUTEnabled"
        static let functionButton1Ability = "functionButton1Ability"
        static let functionButton2Ability = "functionButton2Ability"
        static let isWhiteBalanceLockEnabled = "isWhiteBalanceLockEnabled"
        static let isExposureLockEnabledDuringRecording = "isExposureLockEnabledDuringRecording"
        static let selectedResolutionRaw = "selectedResolutionRaw"
        static let selectedCodecRaw = "selectedCodecRaw"
        static let selectedFrameRate = "selectedFrameRate"
        static let isDebugEnabled = "isDebugEnabled"
        static let showGrid = "showGrid"
        static let selectedLUTURLString = "selectedLUTURLString"
    }
}