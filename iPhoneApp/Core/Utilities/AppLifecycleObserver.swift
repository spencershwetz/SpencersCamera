import SwiftUI
import Combine

// Manages the lifecycle of a UIApplication.didBecomeActiveNotification observer.
class AppLifecycleObserver: ObservableObject {
    // Publisher to signal when the app becomes active
    let didBecomeActivePublisher = PassthroughSubject<Void, Never>()
    
    private var didBecomeActiveObserver: NSObjectProtocol?

    init() {
        print("DEBUG: AppLifecycleObserver init - Adding observer")
        // Register for app state changes to re-enforce orientation when app becomes active
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in // Use weak self
            print("DEBUG: App became active - notification received by AppLifecycleObserver")
            // Send an event on the publisher
            self?.didBecomeActivePublisher.send()
        }
    }

    deinit {
        print("DEBUG: AppLifecycleObserver deinit - Removing observer")
        // Remove the observer when the object is deinitialized
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            didBecomeActiveObserver = nil
        }
    }
} 