import SwiftUI

struct FlashlightSettingsView: View {
    @ObservedObject var settingsModel: SettingsModel
    @StateObject private var flashlightManager = FlashlightManager()
    
    var body: some View {
        Section {
            if flashlightManager.isAvailable {
                Toggle("Enable Recording Light", isOn: $settingsModel.isFlashlightEnabled)
                    .onChange(of: settingsModel.isFlashlightEnabled) { newValue in
                        flashlightManager.isEnabled = newValue
                    }
                
                if settingsModel.isFlashlightEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Light Intensity")
                            Spacer()
                            Text("\(String(format: "%.1f", settingsModel.flashlightIntensity * 100))%")
                        }
                        
                        Slider(value: $settingsModel.flashlightIntensity, in: 0.001...1.0) { editing in
                            flashlightManager.isEnabled = editing
                            flashlightManager.intensity = settingsModel.flashlightIntensity
                        }
                    }
                }
            } else {
                Text("Flashlight not available on this device")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Recording Light")
        } footer: {
            Text("When enabled, the flashlight will be used as a recording indicator light. Adjust the intensity from 0.1% to 100% to your preference.")
        }
        .onDisappear {
            flashlightManager.turnOffForSettingsExit()
        }
    }
} 