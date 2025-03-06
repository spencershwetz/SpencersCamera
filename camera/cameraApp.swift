//
//  cameraApp.swift
//  camera
//
//  Created by spencer on 2024-12-22.
//

import SwiftUI

@main
struct cameraApp: App {
    // Register AppDelegate for orientation control
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            // Wrap ContentView in OrientationFixView for strict orientation control
            OrientationFixView(content: ContentView())
        }
    }
}
