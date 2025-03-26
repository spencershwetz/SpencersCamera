import SwiftUI
import Combine

class DeviceOrientationViewModel: ObservableObject {
    @Published var orientation: UIDeviceOrientation = .portrait
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        print("DEBUG: [OrientationVM] Initializing DeviceOrientationViewModel")
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            .compactMap { _ in UIDevice.current.orientation }
            .filter { orientation in
                // Only handle valid interface orientations
                switch orientation {
                case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
                    print("DEBUG: [OrientationVM] Valid orientation detected: \(orientation.rawValue)")
                    return true
                default:
                    print("DEBUG: [OrientationVM] Ignoring invalid orientation: \(orientation.rawValue)")
                    return false
                }
            }
            .sink { [weak self] newOrientation in
                print("DEBUG: [OrientationVM] Updating orientation to: \(newOrientation.rawValue)")
                withAnimation(.easeInOut(duration: 0.3)) {
                    self?.orientation = newOrientation
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        print("DEBUG: [OrientationVM] Deinitializing DeviceOrientationViewModel")
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
    
    var rotationAngle: Angle {
        switch orientation {
        case .landscapeLeft:
            print("DEBUG: [OrientationVM] Rotating left (90°)")
            return .degrees(-90)
        case .landscapeRight:
            print("DEBUG: [OrientationVM] Rotating right (-90°)")
            return .degrees(90)
        case .portraitUpsideDown:
            print("DEBUG: [OrientationVM] Rotating upside down (180°)")
            return .degrees(180)
        default:
            print("DEBUG: [OrientationVM] No rotation (0°)")
            return .degrees(0)
        }
    }
    
    var rotationOffset: CGSize {
        switch orientation {
        case .landscapeLeft, .landscapeRight:
            print("DEBUG: [OrientationVM] Applying landscape offset")
            return CGSize(width: 0, height: 0)
        default:
            print("DEBUG: [OrientationVM] Applying portrait offset")
            return .zero
        }
    }
} 