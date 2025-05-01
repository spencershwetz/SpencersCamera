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
    static let selectedResolutionChanged = Notification.Name("selectedResolutionChanged")
    static let selectedCodecChanged = Notification.Name("selectedCodecChanged")
    static let selectedFrameRateChanged = Notification.Name("selectedFrameRateChanged")
    static let isDebugEnabledChanged = Notification.Name("isDebugEnabledChanged")
    static let videoStabilizationSettingChanged = Notification.Name("videoStabilizationSettingChanged")
    static let evBiasVisibilityChanged = Notification.Name("evBiasVisibilityChanged")
    static let debugOverlayVisibilityChanged = Notification.Name("debugOverlayVisibilityChanged")
    // Add notifications for function button changes if needed later
}

class SettingsModel: ObservableObject {
    // MARK: - Existing Settings
    @Published var isAppleLogEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAppleLogEnabled, forKey: Keys.isAppleLogEnabled)
            NotificationCenter.default.post(name: .appleLogSettingChanged, object: nil)
            print("Apple Log Enabled: \(isAppleLogEnabled)")
        }
    }
    
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
    
    // MARK: - New Persistent Settings
    @Published var selectedResolutionRaw: String {
        didSet {
            UserDefaults.standard.set(selectedResolutionRaw, forKey: Keys.selectedResolutionRaw)
            NotificationCenter.default.post(name: .selectedResolutionChanged, object: nil)
            print("Selected Resolution: \(selectedResolutionRaw)")
        }
    }
    
    @Published var selectedCodecRaw: String {
        didSet {
            UserDefaults.standard.set(selectedCodecRaw, forKey: Keys.selectedCodecRaw)
            NotificationCenter.default.post(name: .selectedCodecChanged, object: nil)
            print("Selected Codec: \(selectedCodecRaw)")
        }
    }
    
    @Published var selectedFrameRate: Double {
        didSet {
            UserDefaults.standard.set(selectedFrameRate, forKey: Keys.selectedFrameRate)
            NotificationCenter.default.post(name: .selectedFrameRateChanged, object: nil)
            print("Selected Frame Rate: \(selectedFrameRate)")
        }
    }
    
    @Published var isDebugEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isDebugEnabled, forKey: Keys.isDebugEnabled)
            NotificationCenter.default.post(name: .isDebugEnabledChanged, object: nil)
            print("Debug Enabled: \(isDebugEnabled)")
        }
    }
    
    @Published var isVideoStabilizationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isVideoStabilizationEnabled, forKey: Keys.isVideoStabilizationEnabled)
            NotificationCenter.default.post(name: .videoStabilizationSettingChanged, object: nil)
            print("Video Stabilization Enabled: \(isVideoStabilizationEnabled)")
        }
    }
    
    @Published var isEVBiasVisible: Bool {
        didSet {
            UserDefaults.standard.set(isEVBiasVisible, forKey: Keys.isEVBiasVisible)
            NotificationCenter.default.post(name: .evBiasVisibilityChanged, object: nil)
            print("EV Bias Visible: \(isEVBiasVisible)")
        }
    }
    
    @Published var isDebugOverlayVisible: Bool {
        didSet {
            UserDefaults.standard.set(isDebugOverlayVisible, forKey: Keys.isDebugOverlayVisible)
            NotificationCenter.default.post(name: .debugOverlayVisibilityChanged, object: nil)
            print("Debug Overlay Visible: \(isDebugOverlayVisible)")
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
    
    // Computed properties for enum access
    var selectedResolution: CameraViewModel.Resolution {
        CameraViewModel.Resolution(rawValue: selectedResolutionRaw) ?? .hd
    }
    
    var selectedCodec: CameraViewModel.VideoCodec {
        CameraViewModel.VideoCodec(rawValue: selectedCodecRaw) ?? .hevc
    }
    
    // MARK: - Initialization
    init() {
        // 1. Read all initial values from UserDefaults
        let initialAppleLogEnabled = UserDefaults.standard.bool(forKey: Keys.isAppleLogEnabled)
        let initialFlashlightEnabled = UserDefaults.standard.bool(forKey: Keys.isFlashlightEnabled)
        let initialFlashlightIntensity = UserDefaults.standard.float(forKey: Keys.flashlightIntensity)
        let bakeInLUTValue = UserDefaults.standard.object(forKey: Keys.isBakeInLUTEnabled)
        let rawFn1Ability = UserDefaults.standard.string(forKey: Keys.functionButton1Ability)
        let rawFn2Ability = UserDefaults.standard.string(forKey: Keys.functionButton2Ability)
        let initialWhiteBalanceLockEnabled = UserDefaults.standard.bool(forKey: Keys.isWhiteBalanceLockEnabled)
        let initialExposureLockEnabledDuringRecording = UserDefaults.standard.bool(forKey: Keys.isExposureLockEnabledDuringRecording)
        
        // New settings
        let initialResolutionRaw = UserDefaults.standard.string(forKey: Keys.selectedResolutionRaw)
        let initialCodecRaw = UserDefaults.standard.string(forKey: Keys.selectedCodecRaw)
        let initialFrameRate = UserDefaults.standard.double(forKey: Keys.selectedFrameRate)
        let initialDebugEnabled = UserDefaults.standard.object(forKey: Keys.isDebugEnabled) != nil ? UserDefaults.standard.bool(forKey: Keys.isDebugEnabled) : true
        let initialStabilizationEnabled = UserDefaults.standard.object(forKey: Keys.isVideoStabilizationEnabled) != nil ? UserDefaults.standard.bool(forKey: Keys.isVideoStabilizationEnabled) : false
        
        // Visibility settings
        let initialEVBiasVisible = UserDefaults.standard.object(forKey: Keys.isEVBiasVisible) != nil ? UserDefaults.standard.bool(forKey: Keys.isEVBiasVisible) : false
        let initialDebugOverlayVisible = UserDefaults.standard.object(forKey: Keys.isDebugOverlayVisible) != nil ? UserDefaults.standard.bool(forKey: Keys.isDebugOverlayVisible) : false

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
        
        // New settings defaults
        let defaultResolutionRaw = CameraViewModel.Resolution.uhd.rawValue
        let defaultCodecRaw = CameraViewModel.VideoCodec.hevc.rawValue
        let defaultFrameRate = 30.0
        
        let finalResolutionRaw = initialResolutionRaw ?? defaultResolutionRaw
        let finalCodecRaw = initialCodecRaw ?? defaultCodecRaw
        let finalFrameRate = initialFrameRate == 0.0 ? defaultFrameRate : initialFrameRate
        
        let shouldWriteResolutionDefault = initialResolutionRaw == nil
        let shouldWriteCodecDefault = initialCodecRaw == nil
        let shouldWriteFrameRateDefault = initialFrameRate == 0.0
        let shouldWriteDebugDefault = UserDefaults.standard.object(forKey: Keys.isDebugEnabled) == nil
        let shouldWriteStabilizationDefault = UserDefaults.standard.object(forKey: Keys.isVideoStabilizationEnabled) == nil

        // 3. Initialize all @Published properties
        self.isAppleLogEnabled = initialAppleLogEnabled
        self.isFlashlightEnabled = initialFlashlightEnabled
        self.flashlightIntensity = finalFlashlightIntensity
        self.isBakeInLUTEnabled = finalBakeInLUTEnabled
        self.functionButton1Ability = finalFn1Ability
        self.functionButton2Ability = finalFn2Ability
        self.isWhiteBalanceLockEnabled = initialWhiteBalanceLockEnabled
        self.isExposureLockEnabledDuringRecording = initialExposureLockEnabledDuringRecording
        
        // Initialize new settings
        self.selectedResolutionRaw = finalResolutionRaw
        self.selectedCodecRaw = finalCodecRaw
        self.selectedFrameRate = finalFrameRate
        self.isDebugEnabled = initialDebugEnabled
        self.isVideoStabilizationEnabled = initialStabilizationEnabled

        // Initialize visibility settings
        self.isEVBiasVisible = initialEVBiasVisible
        self.isDebugOverlayVisible = initialDebugOverlayVisible
        
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
        
        // Write new settings defaults if they were applied
        if shouldWriteResolutionDefault {
            UserDefaults.standard.set(finalResolutionRaw, forKey: Keys.selectedResolutionRaw)
        }
        if shouldWriteCodecDefault {
            UserDefaults.standard.set(finalCodecRaw, forKey: Keys.selectedCodecRaw)
        }
        if shouldWriteFrameRateDefault {
            UserDefaults.standard.set(finalFrameRate, forKey: Keys.selectedFrameRate)
        }
        if shouldWriteDebugDefault {
            UserDefaults.standard.set(initialDebugEnabled, forKey: Keys.isDebugEnabled)
        }
        if shouldWriteStabilizationDefault {
            UserDefaults.standard.set(initialStabilizationEnabled, forKey: Keys.isVideoStabilizationEnabled)
        }

        // Write defaults if needed
        if UserDefaults.standard.object(forKey: Keys.isEVBiasVisible) == nil {
            UserDefaults.standard.set(false, forKey: Keys.isEVBiasVisible)
        }
        if UserDefaults.standard.object(forKey: Keys.isDebugOverlayVisible) == nil {
            UserDefaults.standard.set(false, forKey: Keys.isDebugOverlayVisible)
        }

        print("SettingsModel initialized:")
        print("- Apple Log: \(isAppleLogEnabled)")
        print("- Flashlight: \(isFlashlightEnabled)")
        print("- Flashlight Intensity: \(flashlightIntensity)")
        print("- Bake LUT: \(isBakeInLUTEnabled)")
        print("- Lock Exposure During Recording: \(isExposureLockEnabledDuringRecording)")
        print("- Fn1: \(functionButton1Ability.rawValue)")
        print("- Fn2: \(functionButton2Ability.rawValue)")
        print("- Resolution: \(selectedResolutionRaw)")
        print("- Codec: \(selectedCodecRaw)")
        print("- Frame Rate: \(selectedFrameRate)")
        print("- Debug Enabled: \(isDebugEnabled)")
        print("- Video Stabilization: \(isVideoStabilizationEnabled)")
    }
    
    // MARK: - Keys for UserDefaults
    private enum Keys {
        static let isAppleLogEnabled = "isAppleLogEnabled"
        static let isFlashlightEnabled = "isFlashlightEnabled"
        static let flashlightIntensity = "flashlightIntensity"
        static let isBakeInLUTEnabled = "isBakeInLUTEnabled"
        static let functionButton1Ability = "functionButton1Ability"
        static let functionButton2Ability = "functionButton2Ability"
        static let isWhiteBalanceLockEnabled = "isWhiteBalanceLockSettingChanged"
        static let isExposureLockEnabledDuringRecording = "isExposureLockEnabledDuringRecording"
        static let selectedResolutionRaw = "selectedResolutionRaw"
        static let selectedCodecRaw = "selectedCodecRaw"
        static let selectedFrameRate = "selectedFrameRate"
        static let isDebugEnabled = "isDebugEnabled"
        static let isVideoStabilizationEnabled = "isVideoStabilizationEnabled"
        static let isEVBiasVisible = "isEVBiasVisible"
        static let isDebugOverlayVisible = "isDebugOverlayVisible"
    }
}