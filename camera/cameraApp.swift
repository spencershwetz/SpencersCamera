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
            // Wrap CameraView in OrientationFixView for strict orientation control
            OrientationFixView {
                CameraView()
            }
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            // ADD: Hide status bar at app level
            .hideStatusBar()
        }
    }
}
