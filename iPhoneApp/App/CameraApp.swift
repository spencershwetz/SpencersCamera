import SwiftUI
import os.log

@main
struct CameraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let logger = Logger(subsystem: "com.camera", category: "CameraApp")
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .onAppear {
                    logger.info("CameraApp MainView appeared")
                }
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - MainView
struct MainView: View {
    @StateObject private var settingsModel = SettingsModel()
    @StateObject private var cameraViewModel: CameraViewModel
    
    init() {
        let settings = SettingsModel()
        _settingsModel = StateObject(wrappedValue: settings)
        _cameraViewModel = StateObject(wrappedValue: CameraViewModel(settingsModel: settings))
    }
    
    var body: some View {
        CameraView(viewModel: cameraViewModel)
            .environmentObject(settingsModel)
    }
} 