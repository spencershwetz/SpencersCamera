import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @StateObject private var lutManager = LUTManager()
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)  // Add black background
            
            CameraPreviewView(session: viewModel.session, 
                            lutManager: lutManager,
                            viewModel: viewModel)
                .edgesIgnoringSafeArea(.all)  // Use newer modifier
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            VStack {
                // Controls content remains the same
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black) // Extra safety black background
        .edgesIgnoringSafeArea(.all)
        .statusBar(hidden: true)
        .preferredColorScheme(.dark) // Force dark mode
        .onAppear {
            // Force dark mode at window level when view appears
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.windows.forEach { window in
                    window.overrideUserInterfaceStyle = .dark
                }
            }
        }
    }
}
