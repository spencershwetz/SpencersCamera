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
    @StateObject private var cameraViewModel = CameraViewModel()
    
    // Get the scene phase
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        // Appearance settings are handled by WindowGroup content and modifiers.
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
                }
            }
            .ignoresSafeArea(.all, edges: .all) // Use standard modifier
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            // Hide status bar at app level
            .hideStatusBar()
            .preferredColorScheme(.dark) // Force dark mode at the SwiftUI level
        }
        // Use onChange to monitor scene phase changes
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .active:
                // print("iOS App Phase: Active")
                cameraViewModel.setAppActive(true)
            case .inactive:
                // print("iOS App Phase: Inactive")
                cameraViewModel.setAppActive(false)
            case .background:
                // print("iOS App Phase: Background")
                cameraViewModel.setAppActive(false)
                // Optionally stop session when going to background if needed
            @unknown default:
                // print("iOS App Phase: Unknown")
                cameraViewModel.setAppActive(false)
            }
        }
    }
}
