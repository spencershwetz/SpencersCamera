//
//  cameraApp.swift
//  camera
//
//  Created by spencer on 2024-12-22.
//

import SwiftUI

@main
struct cameraApp: App {
    let persistenceController = PersistenceController.shared
    // Register AppDelegate for orientation control
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Create a StateObject for the CameraViewModel
    @StateObject private var settingsModel: SettingsModel
    @StateObject private var cameraViewModel: CameraViewModel
    
    // Get the scene phase
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        // Initialize SettingsModel and CameraViewModel with same instance
        let sm = SettingsModel()
        _settingsModel = StateObject(wrappedValue: sm)
        _cameraViewModel = StateObject(wrappedValue: CameraViewModel(settingsModel: sm))
        // REMOVED: Redundant appearance settings, handled by WindowGroup content and modifiers.
        /*
        // Set background color for the entire app to black
        UIWindow.appearance().backgroundColor = UIColor.black
        
        // Force dark mode for the entire app using modern API
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.windows.forEach { window in
                window.overrideUserInterfaceStyle = .dark
            }
        }
        
        // Set dark mode for all windows that will be created
        if #available(iOS 13.0, *) {
            UIWindow.appearance().overrideUserInterfaceStyle = .dark
        }
        
        print("DEBUG: Set window appearance background to black and enforced dark mode")
        */
    }
    
    var body: some Scene {
        WindowGroup {
            // Add background color to root view
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                // Wrap CameraView in OrientationFixView for strict orientation control
                OrientationFixView {
                    // Pass the viewModel instance to CameraView
                    CameraView(viewModel: cameraViewModel)
                        .environmentObject(settingsModel) // Inject SettingsModel
                }
            }
            .ignoresSafeArea(.all, edges: .all) // Use standard modifier
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            // ADD: Hide status bar at app level
            .hideStatusBar()
            .preferredColorScheme(.dark) // Force dark mode at the SwiftUI level
            .onAppear {
                // REMOVED: Redundant appearance settings in onAppear
                /*
                // Set the window's background color and interface style
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first {
                    window.backgroundColor = .black
                    window.overrideUserInterfaceStyle = .dark
                    print("DEBUG: Set window background to black and enforced dark mode")
                    
                    // Apply negative safe area insets to completely remove safe areas
                    window.rootViewController?.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)
                    
                    // Force update layout
                    window.rootViewController?.view.setNeedsLayout()
                    window.rootViewController?.view.layoutIfNeeded()
                }
                */
            }
        }
        // Use onChange to monitor scene phase changes
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .active:
                print("iOS App Phase: Active")
                cameraViewModel.setAppActive(true)
            case .inactive:
                print("iOS App Phase: Inactive")
                cameraViewModel.setAppActive(false)
            case .background:
                print("iOS App Phase: Background")
                cameraViewModel.setAppActive(false)
                // Optionally stop session when going to background if needed
            @unknown default:
                print("iOS App Phase: Unknown")
                cameraViewModel.setAppActive(false)
            }
        }
    }
}
