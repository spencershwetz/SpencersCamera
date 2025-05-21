//
//  SCApp.swift
//  SC Watch App
//
//  Created by spencer on 2025-04-05.
//

import SwiftUI

@main
struct SC_Watch_AppApp: App {
    @StateObject private var connectivityService = WatchConnectivityService.shared
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectivityService)
        }
    }
}
