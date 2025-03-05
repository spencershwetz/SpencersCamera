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
                    
                    VStack {
                        Spacer()
                        controlsView
                            .frame(maxWidth: geometry.size.width * 0.9)
                            .padding(.bottom, 30)
                    }
                } else {
                    ProgressView("Initializing Camera...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.7))
                }
            }
            .edgesIgnoringSafeArea(.all)
        }
        .onAppear {
            viewModel.updateInterfaceOrientation()
        }
        // Remove `.onRotate` – it doesn't exist by default in SwiftUI.
        .onChange(of: UIDevice.current.orientation) { oldValue, newValue in
            viewModel.updateInterfaceOrientation()
        }
        .alert(item: $viewModel.error) { error in
            Alert(
                title: Text("Error"),
                message: Text(error.description),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(lutManager: lutManager)
        }
        .sheet(isPresented: $isShowingDocumentPicker) {
            DocumentPicker(types: LUTManager.supportedTypes) { url in
                DispatchQueue.main.async {
                    handleLUTImport(url: url)
                    isShowingDocumentPicker = false
                }
            }
        }
    }
    
    private var controlsView: some View {
        VStack(spacing: 15) {
            Text("Camera Controls")
                .font(.headline)
            
            HStack {
                Text("FPS:")
                Picker("Frame Rate", selection: $viewModel.selectedFrameRate) {
                    ForEach(viewModel.availableFrameRates, id: \.self) { fps in
                        Text(
                            fps == 29.97
                            ? "29.97"
                            : String(format: "%.2f", fps)
                        )
                        .tag(fps)
                    }
                }
                .pickerStyle(.menu)
            }
            
            HStack {
                Text("WB: \(Int(viewModel.whiteBalance))K")
                Slider(value: $viewModel.whiteBalance, in: 2000...10000, step: 100) {
                    Text("White Balance")
                }
                .onChange(of: viewModel.whiteBalance) { _, newValue in
                    viewModel.updateWhiteBalance(newValue)
                }
            }
            
            HStack {
                Text("Tint: \(Int(viewModel.currentTint))")
                Slider(value: $viewModel.currentTint, in: -150...150, step: 1) {
                    Text("Tint")
                }
                .onChange(of: viewModel.currentTint) { _, newValue in
                    viewModel.updateTint(newValue)
                }
            }
            
            HStack {
                Text("ISO: \(Int(viewModel.iso))")
                Slider(value: $viewModel.iso, in: viewModel.minISO...viewModel.maxISO, step: 1) {
                    Text("ISO")
                }
                .onChange(of: viewModel.iso) { _, newValue in
                    viewModel.updateISO(newValue)
                }
            }
            
            let shutterAngleValue = Int(viewModel.shutterAngle)
            HStack {
                Text("Shutter: \(shutterAngleValue)° (Custom)")
            }
            
            Toggle("LUT Preview", isOn: Binding(
                get: { lutManager.currentLUTFilter != nil },
                set: { _ in } // No direct toggling in example
            ))
            
            Button("Import LUT") {
                isShowingDocumentPicker = true
            }
            
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
            
            if viewModel.isAppleLogSupported {
                Toggle(isOn: $viewModel.isAppleLogEnabled) {
                    HStack {
                        Text("Enable LOG")
                        if viewModel.isAppleLogEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
                .tint(.green)
            }
            
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
        .background(Color.black.opacity(0.3))
        .cornerRadius(15)
        .foregroundColor(.white)
    }
    
    private func handleLUTImport(url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            do {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    print("❌ LUT file does not exist at path: \(url.path)")
                    return
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let fileSize = attributes[.size] as? NSNumber {
                    print("LUT file size: \(fileSize.intValue) bytes")
                }
                self.lutManager.loadLUT(from: url)
            } catch {
                print("Error handling LUT file: \(error.localizedDescription)")
            }
        }
    }
}
