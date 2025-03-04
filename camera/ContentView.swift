import SwiftUI
import CoreData
import CoreMedia

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var orientation = UIDevice.current.orientation
    @StateObject private var lutManager = LUTManager()
    @State private var isShowingSettings = false
    @State private var isShowingDocumentPicker = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if viewModel.isSessionRunning {
                    CameraPreviewView(
                        session: viewModel.session,
                        lutManager: lutManager,
                        viewModel: viewModel
                    )
                    .ignoresSafeArea()
                    .frame(width: geometry.size.width,
                           height: geometry.size.height)
                    
                    VStack {
                        Spacer()
                        controlsView
                            .frame(maxWidth: geometry.size.width * 0.9)
                            .padding(.bottom, 30)
                    }
                } else {
                    // Loading indicator while camera session initializes
                    ProgressView("Initializing Camera...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.7))
                }
            }
            .edgesIgnoringSafeArea(.all)
            .onRotate { newOrientation in
                orientation = newOrientation
            }
        }
        .onAppear {
            viewModel.updateInterfaceOrientation()
        }
        .onChange(of: UIDevice.current.orientation) { oldValue, newValue in
            viewModel.updateInterfaceOrientation()
        }
        .alert(item: $viewModel.error) { error in
            Alert(title: Text("Error"),
                  message: Text(error.description),
                  dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(lutManager: lutManager)
        }
        .sheet(isPresented: $isShowingDocumentPicker) {
            DocumentPicker(types: LUTManager.supportedTypes) { url in
                lutManager.loadLUT(from: url)
                isShowingDocumentPicker = false
            }
        }
    }
    
    // Camera controls
    private var controlsView: some View {
        VStack(spacing: 15) {
            Text("Camera Controls")
                .font(.headline)
            
            // Frame Rate Picker
            HStack {
                Text("FPS:")
                Picker("Frame Rate", selection: $viewModel.selectedFrameRate) {
                    ForEach(viewModel.availableFrameRates, id: \.self) { fps in
                        Text(
                            fps == 29.97 ? "29.97" : 
                            fps == 23.976 ? "23.98" : 
                            String(format: "%.0f", fps)
                        )
                        .tag(fps)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.selectedFrameRate) { oldValue, newValue in
                    viewModel.updateFrameRate(newValue)
                }
            }
            
            // White Balance
            HStack {
                Text("WB: \(Int(viewModel.whiteBalance))K")
                Slider(value: $viewModel.whiteBalance,
                       in: 2000...8000,
                       step: 100) { _ in
                    viewModel.updateWhiteBalance(viewModel.whiteBalance)
                }
            }
            
            // Tint Control
            HStack {
                Text("Tint: \(Int(viewModel.currentTint))")
                Slider(
                    value: $viewModel.currentTint,
                    in: -150...150,
                    step: 1
                ) { _ in
                    viewModel.updateTint(viewModel.currentTint)
                }
                .tint(.green)
            }
            
            // ISO
            HStack {
                Text("ISO: \(Int(viewModel.iso))")
                Slider(value: $viewModel.iso,
                       in: viewModel.minISO...viewModel.maxISO,
                       step: 1) { _ in
                    viewModel.updateISO(viewModel.iso)
                }
            }
            .disabled(viewModel.isAutoExposureEnabled)
            .opacity(viewModel.isAutoExposureEnabled ? 0.6 : 1.0)
            
            // Shutter
            HStack {
                let currentAngle = viewModel.shutterAngle
                Text("Shutter: \(Int(currentAngle))° (\(ShutterAngle(rawValue: currentAngle)?.shutterSpeed ?? "Custom"))")
                
                Picker("Shutter Angle", selection: Binding(
                    get: {
                        // Find the closest standard angle
                        ShutterAngle.allCases.min(by: { abs($0.rawValue - viewModel.shutterAngle) < abs($1.rawValue - viewModel.shutterAngle) })?.rawValue ?? 180.0
                    },
                    set: { newValue in
                        print("\n🎚️ Shutter Angle Changed:")
                        print("  - New Value: \(newValue)°")
                        viewModel.updateShutterAngle(newValue)
                    }
                )) {
                    ForEach(ShutterAngle.allCases, id: \.rawValue) { angle in
                        Text("\(Int(angle.rawValue))° (\(angle.shutterSpeed))")
                            .tag(angle.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            .disabled(viewModel.isAutoExposureEnabled)
            .opacity(viewModel.isAutoExposureEnabled ? 0.6 : 1.0)
            
            // LUT Controls
            VStack(spacing: 8) {
                HStack {
                    Text("LUT Preview")
                    Spacer()
                    if lutManager.currentLUTFilter != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    Toggle("", isOn: Binding(
                        get: { lutManager.currentLUTFilter != nil },
                        set: { enabled in
                            if !enabled {
                                lutManager.clearLUT()
                            } else if let url = lutManager.selectedLUTURL {
                                lutManager.loadLUT(from: url)
                            } else {
                                isShowingDocumentPicker = true
                            }
                        }
                    ))
                    .labelsHidden()
                }
                .tint(.green)
                
                if let lutName = lutManager.selectedLUTURL?.lastPathComponent {
                    HStack {
                        Text(lutName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: {
                            lutManager.clearLUT()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                }
                
                Button(action: {
                    isShowingDocumentPicker = true
                }) {
                    HStack {
                        Image(systemName: "photo.fill")
                        Text("Import LUT")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }
            .padding(.vertical, 4)

            // Auto Exposure toggle
            Toggle(isOn: $viewModel.isAutoExposureEnabled) {
                HStack {
                    Text("Auto Exposure")
                    if viewModel.isAutoExposureEnabled {
                        Image(systemName: "a.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "m.circle.fill")
                            .foregroundColor(.orange)
                    }
                }
            }
            .tint(.green)
            
            // Apple Log toggle if supported
            if viewModel.isAppleLogSupported {
                Toggle(isOn: $viewModel.isAppleLogEnabled) {
                    HStack {
                        Text("Apple Log (4K ProRes)")
                        if viewModel.isAppleLogEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
                .tint(.green)
            }
            
            // Record button
            Button(action: {
                if viewModel.isRecording {
                    viewModel.stopRecording()
                } else {
                    viewModel.startRecording()
                }
            }) {
                Image(systemName: viewModel.isRecording ? "stop.circle" : "record.circle")
                    .font(.system(size: 60))
                    .foregroundColor(viewModel.isRecording ? .white : .red)
                    .opacity(viewModel.isProcessingRecording ? 0.5 : 1.0)
            }
            .disabled(viewModel.isProcessingRecording)
        }
        .padding()
        .background(Color.black.opacity(0.6))
        .cornerRadius(15)
        .foregroundColor(.white)
    }
}

// A rotation view modifier to track device orientation changes
struct DeviceRotationViewModifier: ViewModifier {
    let action: (UIDeviceOrientation) -> Void
    
    func body(content: Content) -> some View {
        content
            .onAppear()
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                action(UIDevice.current.orientation)
            }
    }
}

extension View {
    func onRotate(perform action: @escaping (UIDeviceOrientation) -> Void) -> some View {
        self.modifier(DeviceRotationViewModifier(action: action))
    }
}
