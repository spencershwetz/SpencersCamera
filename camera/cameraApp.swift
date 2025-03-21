//
//  cameraApp.swift
//  camera
//
//  Created by spencer on 2024-12-22.
//

import SwiftUI

@main
struct cameraApp: App {
    // Register AppDelegate for orientation management
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            // OrientationFixView allows system UI (status bar, home indicator) to rotate
            // The CameraView implementation will lock its content to portrait orientation
            OrientationFixView(content: CameraView())
                .onAppear {
                    // We still want the system UI to rotate, but our content will be locked
                    // This unlocks the system orientation only
                    CameraOrientationLock.unlockForRotation()
                    print("🔄 System UI rotation enabled, but app content will be locked to portrait")
                }
        }
    }
}
