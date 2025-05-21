import SwiftUI
import Combine
import os.log
import CoreMotion

/// Coordination model for device orientation that prevents unnecessary view redraws
final class OrientationCoordinator {
    static let shared = OrientationCoordinator()
    
    // Direct access properties that don't trigger view redraws
    private(set) var orientation: UIDeviceOrientation = .portrait
    private(set) var rotationAngleInDegrees: Double = 0
    
    // State change subject that view models can subscribe to
    let orientationChanged = PassthroughSubject<UIDeviceOrientation, Never>()
    let rotationChanged = PassthroughSubject<Double, Never>()
    
    private var cancellables = Set<AnyCancellable>()
    private var orientationObserver: Any?
    private let motionManager = CMMotionManager()
    private let orientationUpdateThreshold: Double = 15.0 // degrees
    private var lastUpdateTime: Date = Date()
    private let updateInterval: TimeInterval = 0.2 // seconds
    
    // Logger for Orientation Coordinator
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "OrientationCoordinator")

    private init() {
        logger.info("Initializing OrientationCoordinator.")
        orientation = UIDevice.current.orientation
        logger.info("Initial device orientation: \(self.orientation.rawValue) - \(String(describing: self.orientation))")
        
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
                self.rotationChanged.send(angle)
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
                guard let self = self else { return }
                if self.orientation != newOrientation {
                    self.orientation = newOrientation
                    self.orientationChanged.send(newOrientation)
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
    
    func rotationAngle() -> Angle {
        .degrees(rotationAngleInDegrees)
    }
    
    var rotationOffset: CGSize {
        .zero // Dynamic offset based on rotation is handled by the rotation angle
    }
}

/// A view-specific orientation view model that subscribes to the shared coordinator
final class DeviceOrientationViewModel: ObservableObject {
    // Legacy shared instance for backward compatibility - will be deprecated
    static let shared = DeviceOrientationViewModel()

    @Published var orientation: UIDeviceOrientation
    @Published var rotationAngleInDegrees: Double
    
    private var cancellables = Set<AnyCancellable>()
    private let coordinator: OrientationCoordinator
    
    init(coordinator: OrientationCoordinator = OrientationCoordinator.shared) {
        self.coordinator = coordinator
        self.orientation = coordinator.orientation
        self.rotationAngleInDegrees = coordinator.rotationAngleInDegrees
        
        // Only subscribe to changes we need
        coordinator.orientationChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] newOrientation in
                self?.orientation = newOrientation
            }
            .store(in: &cancellables)
        
        coordinator.rotationChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] newAngle in
                self?.rotationAngleInDegrees = newAngle
            }
            .store(in: &cancellables)
    }
    
    var rotationAngle: Angle {
        .degrees(rotationAngleInDegrees)
    }
} 