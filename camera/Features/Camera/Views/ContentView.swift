import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @StateObject private var lutManager = LUTManager()
    @State private var showTestOverlay = false // Toggle for testing
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)  // Add black background
            
            CameraPreviewView(session: viewModel.session, 
                            lutManager: lutManager,
                            viewModel: viewModel)
                .edgesIgnoringSafeArea(.all)  // Use newer modifier
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Main content or test overlay
            if showTestOverlay {
                TestDynamicIslandOverlayView()
                    .edgesIgnoringSafeArea(.all)
            } else {
                VStack {
                    // Controls content remains the same
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // Button to toggle test view (bottom right corner)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: {
                        showTestOverlay.toggle()
                    }) {
                        Image(systemName: "ladybug.fill")
                            .font(.system(size: 24))
                            .padding()
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding()
                }
            }
        }
        .background(Color.black) // Extra safety black background
        .ignoresSafeArea(.all, edges: .all) // Use standard modifier
        .statusBar(hidden: true)
        .preferredColorScheme(.dark) // Force dark mode
        .onAppear {
            // Force dark mode at window level when view appears
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.windows.forEach { window in
                    window.overrideUserInterfaceStyle = .dark
                    
                    // Disable safe area insets for the key window
                    if #available(iOS 13.0, *) {
                        window.rootViewController?.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)
                    }
                }
            }
        }
    }
}
