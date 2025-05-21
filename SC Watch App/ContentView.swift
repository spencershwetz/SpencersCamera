//
//  ContentView.swift
//  SC Watch App
//
//  Created by spencer on 2025-04-05.
//

import SwiftUI
import Combine // Import Combine for Timer

struct ContentView: View {
    @EnvironmentObject private var connectivityService: WatchConnectivityService
    
    // Timer for updating elapsed time - Update more frequently for frames
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    @State private var elapsedTimeString: String = "00:00:00:00"
    
    // --- Helper properties to read from latestContext ---
    private var isRecording: Bool {
        connectivityService.latestContext["isRecording"] as? Bool ?? false
    }
    
    private var isAppActive: Bool {
        connectivityService.latestContext["isAppActive"] as? Bool ?? false
    }
    
    private var recordingStartTime: Date? {
        if let startTimeInterval = connectivityService.latestContext["recordingStartTime"] as? TimeInterval {
            return Date(timeIntervalSince1970: startTimeInterval)
        }
        return nil
    }
    
    private var frameRate: Double {
        connectivityService.latestContext["selectedFrameRate"] as? Double ?? 30.0
    }
    // --- End helper properties ---

    var body: some View {
        VStack {
            // Conditional layout based on connection and active state
            if isConnectedAndActive { // Uses computed property reading from context
                // Show full controls when connected and active
                Button(action: {
                    connectivityService.toggleRecording()
                }) {
                    ZStack {
                        Circle()
                            .fill(isRecording ? Color.red : Color.white.opacity(0.8)) // Read from computed property
                            .frame(width: 80, height: 80)
                        
                        if isRecording { // Read from computed property
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white)
                                .frame(width: 30, height: 30)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 50, height: 50)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                // Display Elapsed Time or Ready Text
                Text(buttonStatusText) // Uses computed property reading from context
                    .font(isRecording ? .title2 : .body) // Read from computed property
                    .minimumScaleFactor(0.5) // Allow text to shrink if needed
                    .lineLimit(1)
                    .padding(.top, 5)
                
            } else {
                // Show only the prompt when disconnected or inactive
                Spacer() // Pushes text towards center vertically
                Text(buttonStatusText) // Uses computed property reading from context
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            }
        }
        .padding()
        // Add onReceive modifier for the timer
        .onReceive(timer) { _ in
            updateElapsedTime()
        }
    }
    
    // Computed properties for status display
    private var isConnectedAndActive: Bool {
        // Use the computed property derived from context
        isAppActive
    }
    
    // Computed property for the text below the button
    private var buttonStatusText: String {
        if !isConnectedAndActive {
            return "Open Spencer's Camera on your iPhone"
        } else if isRecording && recordingStartTime != nil { // Use computed properties
            // Return elapsed time when recording
            return elapsedTimeString
        } else {
            // Return "Ready" when not recording but connected/active
            return "Ready"
        }
    }
    
    // Function to update the elapsed time string
    private func updateElapsedTime() {
        // Use computed properties to access state
        guard isRecording, let startTime = recordingStartTime else {
            // Reset if not recording or start time is nil
            if elapsedTimeString != "00:00:00:00" { // Avoid redundant state updates
                 elapsedTimeString = "00:00:00:00"
            }
            return
        }
        
        let now = Date()
        let elapsedTimeInterval = now.timeIntervalSince(startTime)
        
        let elapsedSecondsTotal = Int(elapsedTimeInterval)
        let hours = elapsedSecondsTotal / 3600
        let minutes = (elapsedSecondsTotal % 3600) / 60
        let seconds = elapsedSecondsTotal % 60
        
        // Calculate fractional seconds and frame count
        let fractionalSeconds = elapsedTimeInterval.truncatingRemainder(dividingBy: 1)
        // Use computed property for frame rate
        let currentFrameRate = frameRate > 0 ? frameRate : 30.0 // Use default if 0
        let frame = Int(fractionalSeconds * currentFrameRate)
        
        elapsedTimeString = String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frame)
    }
}

#Preview {
    ContentView()
}
