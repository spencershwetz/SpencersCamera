import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var lutManager: LUTManager
    @ObservedObject var viewModel: CameraViewModel
    @StateObject private var settingsModel = SettingsModel()
    @Binding var isDebugEnabled: Bool
    @State private var isShowingLUTDocumentPicker = false
    var dismissAction: () -> Void
    
    var body: some View {
        NavigationView {
            List {
                Section {
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
                } header: {
                    Text("Camera 🎥")
                }
                
                // LUT Settings Section
                Section {
                    Button(action: {
                        isShowingLUTDocumentPicker = true
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.blue)
                            Text("Import LUT")
                        }
                    }
                    
                    if lutManager.currentLUTFilter != nil {
                        HStack {
                            Text("Current LUT")
                            Spacer()
                            Text(lutManager.currentLUTName)
                                .foregroundColor(.secondary)
                        }
                        
                        Toggle(isOn: $settingsModel.isBakeInLUTEnabled) {
                            HStack {
                                Text("Bake in LUT")
                                if settingsModel.isBakeInLUTEnabled {
                                    Image(systemName: "checkmark.square.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .tint(.blue)
                        
                        Button(action: {
                            lutManager.clearLUT()
                        }) {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text("Remove Current LUT")
                            }
                        }
                    }
                    
                    if let recentLUTs = lutManager.recentLUTs, !recentLUTs.isEmpty {
                        ForEach(Array(recentLUTs.keys), id: \.self) { name in
                            if let url = recentLUTs[name] {
                                Button(action: {
                                    lutManager.loadLUT(from: url)
                                }) {
                                    HStack {
                                        Image(systemName: "photo.fill")
                                            .foregroundColor(.blue)
                                        Text(name)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Color LUTs 🎨")
                } footer: {
                    if lutManager.currentLUTFilter != nil {
                        Text("When 'Bake in LUT' is enabled, the LUT color profile will be permanently applied to your recorded video. When disabled, the preview will still show the LUT effect, but the original camera footage will be recorded.")
                    }
                }
                
                // Flashlight Settings
                FlashlightSettingsView(settingsModel: settingsModel)
                
                Section {
                    Toggle(isOn: $isDebugEnabled) {
                        HStack {
                            Text("Show Debug Info")
                            if isDebugEnabled {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                } header: {
                    Text("Display")
                }
                
                Section {
                    Text("Storage settings will go here")
                } header: {
                    Text("Storage")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismissAction()
                    }
                }
            }
            .sheet(isPresented: $isShowingLUTDocumentPicker) {
                DocumentPicker(types: LUTManager.supportedTypes) { url in
                    lutManager.importLUT(from: url) { success in
                        if success {
                            print("LUT imported successfully")
                        }
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
        isDebugEnabled: .constant(false),
        dismissAction: {}
    )
} 