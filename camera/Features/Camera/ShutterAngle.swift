import Foundation

enum ShutterAngle: Double, CaseIterable {
    case angle_360 = 360.0  // 1/24
    case angle_345_6 = 345.6  // 1/25
    case angle_288 = 288.0  // 1/30
    case angle_262_2 = 262.2  // 1/33
    case angle_180 = 180.0  // 1/48
    case angle_172_8 = 172.8  // 1/50
    case angle_144 = 144.0  // 1/60
    case angle_90 = 90.0   // 1/96
    case angle_86_4 = 86.4  // 1/100
    case angle_72 = 72.0   // 1/120
    case angle_69_1 = 69.1  // 1/125
    case angle_34_6 = 34.6  // 1/250
    case angle_17_3 = 17.3  // 1/500
    case angle_8_6 = 8.6   // 1/1000
    case angle_4_3 = 4.3   // 1/2000
    case angle_2_2 = 2.2   // 1/4000
    case angle_1_1 = 1.1   // 1/8000
    
    var shutterSpeed: String {
        switch self {
        case .angle_360: return "1/24"
        case .angle_345_6: return "1/25"
        case .angle_288: return "1/30"
        case .angle_262_2: return "1/33"
        case .angle_180: return "1/48"
        case .angle_172_8: return "1/50"
        case .angle_144: return "1/60"
        case .angle_90: return "1/96"
        case .angle_86_4: return "1/100"
        case .angle_72: return "1/120"
        case .angle_69_1: return "1/125"
        case .angle_34_6: return "1/250"
        case .angle_17_3: return "1/500"
        case .angle_8_6: return "1/1000"
        case .angle_4_3: return "1/2000"
        case .angle_2_2: return "1/4000"
        case .angle_1_1: return "1/8000"
        }
    }
} 