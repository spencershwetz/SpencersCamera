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
            // Content now supports device rotation
            OrientationFixView(content: CameraView())
                .onAppear {
                    // Ensure orientation is unlocked for rotation when app appears
                    CameraOrientationLock.unlockForRotation()
                }
        }
    }
}
