import Foundation
import CoreLocation
import Combine
import UIKit

/// A lightweight service that fetches the user's current geographic location with best-accuracy settings.
/// The service starts location updates when requested and stops them when no longer needed.
///
/// Usage:
/// ```swift
/// let locationService = LocationService.shared
/// locationService.startUpdating()
/// // access locationService.currentLocation when available
/// ```
final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    @Published private(set) var currentLocation: CLLocation?

    private let locationManager: CLLocationManager
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        self.locationManager = CLLocationManager()
        super.init()
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // Use significant change only for power savings when not actively recording.
        self.locationManager.activityType = .other
        // Observe authorization changes to automatically start updates if permission granted.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.locationManager.authorizationStatus == .authorizedWhenInUse {
                    self.locationManager.requestLocation()
                }
            }
            .store(in: &cancellables)
    }

    /// Requests authorization (When-In-Use) if not already determined.
    func requestAuthorizationIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    /// Begin updating the user's location. Call this at the start of a recording session.
    func startUpdating() {
        requestAuthorizationIfNeeded()
        if locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.startUpdatingLocation()
        }
    }

    /// Stop updating to save battery. Call this when recording stops.
    func stopUpdating() {
        locationManager.stopUpdatingLocation()
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let latest = locations.last {
            currentLocation = latest
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silently ignore for now; we don't surface location errors to the UI.
        print("LocationService error: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse {
            // Immediately request a single location update.
            manager.requestLocation()
        }
    }
} 