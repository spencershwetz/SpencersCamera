import SwiftUI
import Combine
import os.log
import CoreMotion

/// A shared observable object that tracks the device's physical orientation.
final class DeviceOrientationViewModel: ObservableObject {
    static let shared = DeviceOrientationViewModel()

    @Published var orientation: UIDeviceOrientation = .portrait
    @Published var rotationAngleInDegrees: Double = 0
    
    private var cancellables = Set<AnyCancellable>()
    private var orientationObserver: Any?
    private let motionManager = CMMotionManager()
    private let orientationUpdateThreshold: Double = 15.0 // degrees
    private var lastUpdateTime: Date = Date()
    private let updateInterval: TimeInterval = 0.2 // seconds
    
    // Logger for Orientation ViewModel
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "DeviceOrientationVM")

    private init() {
        logger.info("Initializing DeviceOrientationViewModel.")
        orientation = UIDevice.current.orientation
        logger.info("Initial device orientation: \\(orientation.rawValue) - \\(String(describing: orientation))")
        
        setupMotionUpdates()
        setupOrientationNotifications()
    }
    
    private func setupMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            logger.warning("Device motion is not available")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = updateInterval
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self,
                  let motion = motion,
                  Date().timeIntervalSince(self.lastUpdateTime) >= self.updateInterval else { return }
            
            let gravity = motion.gravity
            let angle = atan2(gravity.x, gravity.y) * (180.0 / .pi)
            
            // Only update if the change is significant
            if abs(angle - self.rotationAngleInDegrees) >= self.orientationUpdateThreshold {
                self.rotationAngleInDegrees = angle
                self.lastUpdateTime = Date()
                self.logger.debug("Updated rotation angle: \\(angle)")
            }
        }
    }
    
    private func setupOrientationNotifications() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            .compactMap { _ in UIDevice.current.orientation }
            .filter { orientation in
                switch orientation {
                case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
                    return true
                default:
                    return false
                }
            }
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] newOrientation in
                withAnimation(.easeInOut(duration: 0.3)) {
                    self?.orientation = newOrientation
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        motionManager.stopDeviceMotionUpdates()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    var rotationAngle: Angle {
        .degrees(rotationAngleInDegrees)
    }
    
    var rotationOffset: CGSize {
        .zero // Dynamic offset based on rotation is handled by the rotation angle
    }
} 