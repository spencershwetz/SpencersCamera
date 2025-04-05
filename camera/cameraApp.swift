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
    
    var body: some Scene {
        WindowGroup {
            // Add background color to root view
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                // Wrap CameraView in OrientationFixView for strict orientation control
                CameraView()
            }
            .ignoresSafeArea(.all) 
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            // ADD: Hide status bar at app level
            .hideStatusBar()
            .onAppear {
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
            }
        }
    }
}
