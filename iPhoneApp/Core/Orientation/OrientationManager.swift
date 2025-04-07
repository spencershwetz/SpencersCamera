import SwiftUI
import Combine

class OrientationManager: ObservableObject {
    static let shared = OrientationManager() // Shared instance

    @Published var currentOrientationMask: UIInterfaceOrientationMask = .portrait

    private init() {} // Private initializer for singleton pattern

    func updateOrientationMask(_ mask: UIInterfaceOrientationMask) {
        // Ensure updates happen on the main thread if called from background
        DispatchQueue.main.async {
            if self.currentOrientationMask != mask {
                self.currentOrientationMask = mask
                print("🔄 OrientationManager: Updated mask to \(mask == .portrait ? "Portrait" : "All")")
                // Optional: Force UI update if needed, though @Published should handle it.
                // UIViewController.attemptRotationToDeviceOrientation()
                
                // Trigger an update of supported orientations application-wide
                // This notifies the system to re-query the AppDelegate
                 if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                     windowScene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
                 }
            }
        }
    }
} 