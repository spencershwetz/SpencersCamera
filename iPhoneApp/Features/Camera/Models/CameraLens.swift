import AVFoundation

enum CameraLens: String, CaseIterable {
    case ultraWide = "0.5"
    case wide = "1"
    case x2 = "2"
    case telephoto = "5"
    
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide: return .builtInWideAngleCamera
        case .x2: return .builtInWideAngleCamera // Uses digital zoom on wide lens
        case .telephoto: return .builtInTelephotoCamera
        }
    }
    
    var zoomFactor: CGFloat {
        switch self {
        case .ultraWide: return 0.5
        case .wide: return 1.0
        case .x2: return 2.0
        case .telephoto: return 5.0
        }
    }
    
    var systemImageName: String {
        switch self {
        case .ultraWide: return "camera.lens.ultra.wide"
        case .wide: return "camera.lens.wide"
        case .x2: return "camera.lens.wide"
        case .telephoto: return "camera.lens.telephoto"
        }
    }
    
    static func availableLenses() -> [CameraLens] {
        var lenses = CameraLens.allCases.filter { lens in
            // For 2x, we only need the wide angle camera
            if lens == .x2 {
                return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            }
            return AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) != nil
        }
        
        // Sort lenses by zoom factor
        lenses.sort { $0.zoomFactor < $1.zoomFactor }
        return lenses
    }
} 