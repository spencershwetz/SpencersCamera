import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var lutManager: LUTManager
    @ObservedObject var viewModel: CameraViewModel
    @Binding var isDebugEnabled: Bool
    
    var body: some View {
        NavigationView {
            List {
                Section("Camera 🎥") {
                    // Resolution
                    Picker("Resolution", selection: $viewModel.selectedResolution) {
                        ForEach(CameraViewModel.Resolution.allCases, id: \.self) { resolution in
                            Text(resolution.rawValue).tag(resolution)
                        }
                    }
                    
                    // Color Space
                    Picker("Color Space", selection: selectedColorSpace) {
                        ForEach(colorSpaceOptions, id: \.self) { colorSpace in
                            Text(colorSpace).tag(colorSpace)
                        }
                    }
                    
                    // Codec
                    Picker("Codec", selection: $viewModel.selectedCodec) {
                        ForEach(CameraViewModel.VideoCodec.allCases, id: \.self) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }
                    
                    // Frame Rate
                    Picker("Frame Rate", selection: $viewModel.selectedFrameRate) {
                        ForEach(viewModel.availableFrameRates, id: \.self) { fps in
                            Text(fps == 29.97 ? "29.97" : String(format: "%.2f", fps))
                                .tag(fps)
                        }
                    }
                }
                
                Section("Display") {
                    Toggle(isOn: $isDebugEnabled) {
                        HStack {
                            Text("Show Debug Info")
                            if isDebugEnabled {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                
                Section("Storage") {
                    Text("Storage settings will go here")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    // Color space options
    private let colorSpaceOptions = [
        "Rec.709",
        "Apple Log"
    ]
    
    // Binding for color space that updates Apple Log
    private var selectedColorSpace: Binding<String> {
        Binding(
            get: { viewModel.isAppleLogEnabled ? "Apple Log" : "Rec.709" },
            set: { newValue in
                viewModel.isAppleLogEnabled = (newValue == "Apple Log")
            }
        )
    }
}

#Preview {
    SettingsView(
        lutManager: LUTManager(),
        viewModel: CameraViewModel(),
        isDebugEnabled: .constant(false)
    )
} 