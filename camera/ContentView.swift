import SwiftUI
import CoreData
import CoreMedia
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var orientation = UIDevice.current.orientation
    @StateObject private var lutManager = LUTManager()
    @State private var isShowingSettings = false
    @State private var isShowingDocumentPicker = false
    @State private var uiOrientation = UIDeviceOrientation.portrait
    
    // Add AppDelegate notification for more consistent orientation locking
    init() {
        setupOrientationNotifications()
    }
    
    private func setupOrientationNotifications() {
        // Register for app state changes to re-enforce orientation when app becomes active
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("DEBUG: App became active - re-enforcing camera orientation")
            viewModel.updateInterfaceOrientation(lockCamera: true)
        }
    }
    
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
                    // Fixed frame that won't change with rotation
                    .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                    // Disable all animations that might be triggered by rotation
                    .animation(.none)
                    // Prevent interactions from affecting the preview
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
                    
                    VStack {
                        Spacer()
                        controlsView
                            .frame(maxWidth: uiOrientation.isPortrait ? geometry.size.width * 0.9 : geometry.size.width * 0.95)
                            .padding(.bottom, uiOrientation.isPortrait ? 30 : 15)
                            .rotationEffect(rotationAngle(for: uiOrientation))
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
            // Double enforce the orientation lock on appear
            viewModel.updateInterfaceOrientation(lockCamera: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                viewModel.updateInterfaceOrientation(lockCamera: true)
            }
        }
        .onChange(of: UIDevice.current.orientation) { oldValue, newValue in
            if newValue.isValidInterfaceOrientation {
                print("DEBUG: ContentView - Device orientation changed to \(newValue.rawValue)")
                uiOrientation = newValue
                // Always lock camera preview orientation
                viewModel.updateInterfaceOrientation(lockCamera: true)
                
                // Re-enforce after a short delay to catch any late layout updates
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    viewModel.updateInterfaceOrientation(lockCamera: true)
                }
            }
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
        Group {
            if uiOrientation.isPortrait {
                portraitControlsLayout
            } else {
                landscapeControlsLayout
            }
        }
        .padding()
        .background(Color.black.opacity(0.3))
        .cornerRadius(15)
        .foregroundColor(.white)
    }
    
    private var portraitControlsLayout: some View {
        VStack(spacing: 15) {
            controlsHeader
            framerateControl
            whiteBalanceControl
            tintControl
            isoControl
            shutterAngleDisplay
            lutControls
            exposureControls
            appleLogToggle
            recordButton
        }
    }
    
    private var landscapeControlsLayout: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 15) {
                controlsHeader
                framerateControl
                whiteBalanceControl
                tintControl
            }
            
            VStack(spacing: 15) {
                isoControl
                shutterAngleDisplay
                lutControls
                exposureControls
                appleLogToggle
            }
            
            VStack {
                Spacer()
                recordButton
                    .padding(.bottom, 10)
            }
        }
    }
    
    private var controlsHeader: some View {
        Text("Camera Controls")
            .font(.headline)
    }
    
    private var framerateControl: some View {
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
    }
    
    private var whiteBalanceControl: some View {
        HStack {
            Text("WB: \(Int(viewModel.whiteBalance))K")
            Slider(value: $viewModel.whiteBalance, in: 2000...10000, step: 100) {
                Text("White Balance")
            }
            .onChange(of: viewModel.whiteBalance) { _, newValue in
                viewModel.updateWhiteBalance(newValue)
            }
        }
    }
    
    private var tintControl: some View {
        HStack {
            Text("Tint: \(Int(viewModel.currentTint))")
            Slider(value: $viewModel.currentTint, in: -150...150, step: 1) {
                Text("Tint")
            }
            .onChange(of: viewModel.currentTint) { _, newValue in
                viewModel.updateTint(newValue)
            }
        }
    }
    
    private var isoControl: some View {
        HStack {
            Text("ISO: \(Int(viewModel.iso))")
            Slider(value: $viewModel.iso, in: viewModel.minISO...viewModel.maxISO, step: 1) {
                Text("ISO")
            }
            .onChange(of: viewModel.iso) { _, newValue in
                viewModel.updateISO(newValue)
            }
        }
    }
    
    private var shutterAngleDisplay: some View {
        let shutterAngleValue = Int(viewModel.shutterAngle)
        return HStack {
            Text("Shutter: \(shutterAngleValue)° (Custom)")
        }
    }
    
    private var lutControls: some View {
        VStack {
            Toggle("LUT Preview", isOn: Binding(
                get: { lutManager.currentLUTFilter != nil },
                set: { _ in } // No direct toggling in example
            ))
            
            Button("Import LUT") {
                isShowingDocumentPicker = true
            }
        }
    }
    
    private var exposureControls: some View {
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
    }
    
    private var appleLogToggle: some View {
        Group {
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
            } else {
                EmptyView()
            }
        }
    }
    
    private var recordButton: some View {
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
    
    private func rotationAngle(for orientation: UIDeviceOrientation) -> Angle {
        switch orientation {
        case .portrait:
            return .zero
        case .portraitUpsideDown:
            return .degrees(180)
        case .landscapeLeft:
            return .degrees(90)
        case .landscapeRight:
            return .degrees(-90)
        default:
            return .zero
        }
    }
}

// MARK: - UIDeviceOrientation Extensions
extension UIDeviceOrientation {
    var isPortrait: Bool {
        return self == .portrait || self == .portraitUpsideDown
    }
    
    var isLandscape: Bool {
        return self == .landscapeLeft || self == .landscapeRight
    }
}
