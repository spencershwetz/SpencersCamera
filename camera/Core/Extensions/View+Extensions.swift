import SwiftUI
import UIKit

// View extension to disable safe area insets completely
extension View {
    func disableSafeArea() -> some View {
        self.modifier(SafeAreaDisabler())
    }
}

// A UIViewControllerRepresentable that completely disables safe area insets
struct SafeAreaDisabler: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SafeAreaDisablerView())
            .ignoresSafeArea(.all)
    }
}

struct SafeAreaDisablerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        SafeAreaDisablerController()
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
    
    private class SafeAreaDisablerController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            // Make view transparent
            view.backgroundColor = .clear
            // Disable safe area insets for this controller
            self.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)
        }
        
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // Force negative insets to override the system safe areas
            self.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)
        }
        
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // Apply negative insets after layout
            self.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)
        }
        
        override var preferredStatusBarStyle: UIStatusBarStyle {
            return .lightContent
        }
        
        override var prefersStatusBarHidden: Bool {
            return true
        }
    }
} 