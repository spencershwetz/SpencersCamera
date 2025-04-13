import SwiftUI
import Combine
import os.log

/// A shared observable object that tracks the device's physical orientation.
final class DeviceOrientationViewModel: ObservableObject {
    static let shared = DeviceOrientationViewModel()

    @Published var orientation: UIDeviceOrientation = .portrait
    private var cancellables = Set<AnyCancellable>()
    private var orientationObserver: Any?
    
    // Logger for Orientation ViewModel
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "DeviceOrientationVM")

    private init() {
        logger.info("Initializing DeviceOrientationViewModel.")
        orientation = UIDevice.current.orientation
        logger.info("Initial device orientation: \\(orientation.rawValue) - \\(String(describing: orientation))")
        
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            .compactMap { _ in UIDevice.current.orientation }
            .filter { orientation in
                // Only handle valid interface orientations
                switch orientation {
                case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
                    // print("DEBUG: [OrientationVM] Valid orientation detected: \\(orientation.rawValue)")
                    return true
                default:
                    // print("DEBUG: [OrientationVM] Ignoring invalid orientation: \\(orientation.rawValue)")
                    return false
                }
            }
            .sink { [weak self] newOrientation in
                // print("DEBUG: [OrientationVM] Updating orientation to: \\(newOrientation.rawValue)")
                withAnimation(.easeInOut(duration: 0.3)) {
                    self?.orientation = newOrientation
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        // print("DEBUG: [OrientationVM] Deinitializing DeviceOrientationViewModel")
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        logger.info("Stopping device orientation observation.")
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    var rotationAngle: Angle {
        logger.debug("Calculating UI rotationAngle for device orientation: \\(orientation.rawValue)")
        let angle: Angle
        switch orientation {
        case .landscapeLeft:
            logger.debug("UI Rotation: Landscape Left -> -90 degrees")
            angle = .degrees(-90)
        case .landscapeRight:
            logger.debug("UI Rotation: Landscape Right -> 90 degrees")
            angle = .degrees(90)
        case .portraitUpsideDown:
            logger.debug("UI Rotation: Portrait Upside Down -> 180 degrees")
            angle = .degrees(180)
        default: // .portrait, .unknown, .faceUp, .faceDown
            logger.debug("UI Rotation: Portrait/Other -> 0 degrees")
            angle = .degrees(0)
        }
        return angle
    }
    
    var rotationOffset: CGSize {
        logger.debug("Calculating UI rotationOffset for device orientation: \\(orientation.rawValue)")
        let offset: CGSize
        switch orientation {
        case .landscapeLeft, .landscapeRight:
            logger.debug("UI Offset: Landscape -> Zero")
            offset = CGSize(width: 0, height: 0) // No offset needed in landscape for simple rotations
        default:
            logger.debug("UI Offset: Portrait/Other -> Zero")
            offset = .zero
        }
        return offset
    }
} 