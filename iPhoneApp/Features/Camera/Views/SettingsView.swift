import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var lutManager: LUTManager
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var settingsModel: SettingsModel
    var dismissAction: () -> Void
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    // Resolution - Now using the selectedResolutionRaw binding
                    Picker("Resolution", selection: $settingsModel.selectedResolutionRaw) {
                        ForEach(CameraViewModel.Resolution.allCases, id: \.self) { resolution in
                            Text(resolution.rawValue).tag(resolution.rawValue)
                        }
                    }
                    .onChange(of: settingsModel.selectedResolutionRaw) { _, newValue in
                        if let resolution = CameraViewModel.Resolution(rawValue: newValue) {
                            viewModel.updateResolution(resolution)
                        }
                    }
                    
                    // Color Space - Keeping as is since it was already using a custom binding
                    Picker("Color Space", selection: selectedColorSpace) {
                        ForEach(colorSpaceOptions, id: \.self) { colorSpace in
                            Text(colorSpace).tag(colorSpace)
                        }
                    }
                    
                    // Codec - Now using selectedCodecRaw binding
                    Picker("Codec", selection: $settingsModel.selectedCodecRaw) {
                        ForEach(CameraViewModel.VideoCodec.allCases, id: \.self) { codec in
                            Text(codec.rawValue).tag(codec.rawValue)
                        }
                    }
                    .onChange(of: settingsModel.selectedCodecRaw) { _, newValue in
                        if let codec = CameraViewModel.VideoCodec(rawValue: newValue) {
                            viewModel.updateCodec(codec)
                        }
                    }
                    
                    // Frame Rate - Now using settingsModel.selectedFrameRate
                    Picker("Frame Rate", selection: $settingsModel.selectedFrameRate) {
                        ForEach(viewModel.availableFrameRates, id: \.self) { fps in
                            Text(fps == 29.97 ? "29.97" : String(format: "%.2f", fps))
                                .tag(fps)
                        }
                    }
                    .onChange(of: settingsModel.selectedFrameRate) { _, newFps in
                        viewModel.updateFrameRate(newFps)
                    }

                    Toggle(isOn: $settingsModel.isWhiteBalanceLockEnabled) {
                        HStack {
                            Text("Lock White Balance During Recording")
                            if settingsModel.isWhiteBalanceLockEnabled {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .tint(.blue)
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
                    
                    if !lutManager.availableLUTs.isEmpty {
                        ForEach(Array(lutManager.availableLUTs.keys.sorted()), id: \.self) { name in
                            if let url = lutManager.availableLUTs[name] {
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
                
                // Exposure Settings Section
                Section {
                    Toggle(isOn: $settingsModel.isExposureLockEnabledDuringRecording) {
                        HStack {
                            Text("Lock Exposure During Recording")
                            if settingsModel.isExposureLockEnabledDuringRecording {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .tint(.blue)
                } header: {
                    Text("Exposure")
                }
                
                // Flashlight Settings
                FlashlightSettingsView(settingsModel: settingsModel)
                
                Section {
                    Toggle(isOn: $settingsModel.isDebugEnabled) {
                        HStack {
                            Text("Show Debug Info")
                            if settingsModel.isDebugEnabled {
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
    
    // State to manage document picker presentation
    @State private var isShowingLUTDocumentPicker = false
    
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
                viewModel.updateColorSpace(isAppleLogEnabled: newValue == "Apple Log")
            }
        )
    }
}

#Preview {
    SettingsView(
        lutManager: LUTManager(),
        viewModel: CameraViewModel(),
        settingsModel: SettingsModel(),
        dismissAction: {}
    )
} 