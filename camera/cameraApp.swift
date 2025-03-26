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
    
    init() {
        // Set background color for the entire app to black
        UIWindow.appearance().backgroundColor = UIColor.black
        print("DEBUG: Set window appearance background to black")
    }
    
    var body: some Scene {
        WindowGroup {
            // Add background color to root view
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                // Wrap CameraView in OrientationFixView for strict orientation control
                OrientationFixView {
                    RotatingView {
                        ContentView()
                    }
                }
            }
            .disableSafeArea() // Use our custom modifier to completely disable safe areas
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            // ADD: Hide status bar at app level
            .hideStatusBar()
            .preferredColorScheme(.dark)  // ADD: Force dark mode
            .onAppear {
                // Set the window's background color
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first {
                    window.backgroundColor = .black
                    print("DEBUG: Set window background to black")
                    
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
