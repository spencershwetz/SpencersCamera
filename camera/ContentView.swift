import SwiftUI
import CoreData
import CoreMedia

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var orientation = UIDevice.current.orientation
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if viewModel.isSessionRunning {
                    CameraPreviewView(session: viewModel.session)
                        .ignoresSafeArea()
                        .frame(width: geometry.size.width,
                               height: geometry.size.height)
                    
                    VStack {
                        Spacer()
                        controlsView
                            // Ensure controls are centered and fully visible on screen
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
                        Text(fps == 29.97 ? "29.97" : String(format: "%.0f", fps))
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
            
            // Shutter
            HStack {
                // Display shutter as 1/x
                let fraction = Double(viewModel.shutterSpeed.timescale) / Double(viewModel.shutterSpeed.value)
                Text("Shutter: 1/\(Int(fraction))")
                Slider(value: .init(get: {
                    Float(fraction)
                }, set: { newValue in
                    viewModel.updateShutterSpeed(CMTimeMake(value: 1, timescale: Int32(newValue)))
                }), in: 15...8000, step: 1)
            }
            
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
