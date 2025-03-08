import SwiftUI
import CoreData
import CoreMedia
import UIKit

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var orientation = UIDevice.current.orientation
    @StateObject private var lutManager = LUTManager()
    @State private var isShowingSettings = false
    @State private var isShowingDocumentPicker = false
    @State private var uiOrientation = UIDeviceOrientation.portrait
    @State private var showLUTPreview = true
    
    // Initialize with proper handling of StateObjects
    init() {
        // We CANNOT access @StateObject properties here as they won't be initialized yet
        // Only setup notifications that don't depend on StateObjects
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
            // We CANNOT reference viewModel directly here - it causes the error
            // Instead, we'll handle this in onAppear or through a dedicated @State property
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if viewModel.isSessionRunning {
                    // Camera is running - show camera preview
                    CameraPreviewView(
                        session: viewModel.session,
                        lutManager: lutManager,
                        viewModel: viewModel
                    )
                    .ignoresSafeArea()
                    // Fixed frame that won't change with rotation
                    .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                    // Prevent animations that might be triggered by rotation
                    .transaction { transaction in 
                        transaction.animation = nil
                    }
                    
                    // LUT preview indicator
                    if lutManager.currentLUTFilter != nil && showLUTPreview {
                        VStack {
                            HStack {
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("LUT ACTIVE")
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                    
                                    Text(lutManager.currentLUTName)
                                        .font(.caption)
                                        .foregroundColor(.white)
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.black.opacity(0.7))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(Color.green, lineWidth: 2)
                                        )
                                )
                                .padding(.top, 50)
                                .padding(.trailing, 16)
                            }
                            Spacer()
                        }
                    }
                    
                    // Adaptive camera controls that reposition for orientation
                    adaptiveControlsView(in: geometry)
                } else {
                    // Camera is initializing - show loading
                    ZStack {
                        // Black background
                        Color.black.edgesIgnoringSafeArea(.all)
                        
                        // Loading indicator
                        VStack(spacing: 20) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            
                            Text("Initializing Camera...")
                                .foregroundColor(.white)
                                .font(.headline)
                            
                            // Show error if there is one
                            if let error = viewModel.error {
                                Text(error.description)
                                    .foregroundColor(.red)
                                    .font(.subheadline)
                                    .padding()
                                    .background(Color.black.opacity(0.7))
                                    .cornerRadius(8)
                            }
                            
                            // Retry button
                            if viewModel.status == .failed || viewModel.status == .unauthorized {
                                Button("Try Again") {
                                    print("DEBUG: Manually attempting to start camera session")
                                    viewModel.status = .unknown
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        viewModel.session.startRunning()
                                        DispatchQueue.main.async {
                                            viewModel.isSessionRunning = viewModel.session.isRunning
                                            viewModel.status = viewModel.session.isRunning ? .running : .failed
                                        }
                                    }
                                }
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                        }
                    }
                }
            }
            .edgesIgnoringSafeArea(.all)
        }
        .onAppear {
            // Start the camera session if needed
            if !viewModel.session.isRunning {
                print("DEBUG: Camera session not running on view appear")
                DispatchQueue.global(qos: .userInitiated).async {
                    viewModel.session.startRunning()
                    DispatchQueue.main.async {
                        viewModel.isSessionRunning = viewModel.session.isRunning
                        viewModel.status = viewModel.session.isRunning ? .running : .failed
                        print("DEBUG: Camera session now running: \(viewModel.session.isRunning)")
                    }
                }
            }
            
            // Double enforce the orientation lock on appear
            viewModel.updateInterfaceOrientation(lockCamera: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                viewModel.updateInterfaceOrientation(lockCamera: true)
            }
            
            // Set up notification handler for app becoming active - PROPER place to access StateObject
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [self] _ in
                print("DEBUG: App became active - re-enforcing camera orientation")
                viewModel.updateInterfaceOrientation(lockCamera: true)
            }
            
            // Share LUTManager between views
            viewModel.lutManager = lutManager
            
            // Ensure LUT preview is on by default when a LUT is loaded
            showLUTPreview = true
        }
        .onDisappear {
            // Remove notification observer when the view disappears
            NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
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
        .onChange(of: lutManager.currentLUTFilter) { oldValue, newValue in
            // When LUT changes, update preview indicator
            if newValue != nil {
                print("DEBUG: LUT filter updated to: \(lutManager.currentLUTName)")
                // Automatically turn on preview when a new LUT is loaded
                showLUTPreview = true
            } else {
                print("DEBUG: LUT filter removed")
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
    
    // New adaptive controls placement based on orientation
    private func adaptiveControlsView(in geometry: GeometryProxy) -> some View {
        Group {
            if uiOrientation.isPortrait {
                // Portrait controls at the bottom
                VStack {
                    Spacer()
                    controlsView
                        .frame(maxWidth: geometry.size.width * 0.95)
                        .padding(.bottom, 30)
                }
            } else if uiOrientation == .landscapeRight {
                // Landscape Right - controls on the left side
                HStack {
                    controlsView
                        .frame(maxWidth: geometry.size.width * 0.7, maxHeight: geometry.size.height * 0.9)
                        .padding(.leading, 20)
                    Spacer()
                }
                .rotationEffect(rotationAngle(for: uiOrientation))
            } else if uiOrientation == .landscapeLeft {
                // Landscape Left - controls on the right side
                HStack {
                    Spacer()
                    controlsView
                        .frame(maxWidth: geometry.size.width * 0.7, maxHeight: geometry.size.height * 0.9)
                        .padding(.trailing, 20)
                }
                .rotationEffect(rotationAngle(for: uiOrientation))
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
        .background(Color.black.opacity(0.5))
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
        HStack(alignment: .center, spacing: 20) {
            // Left column - basic adjustments
            VStack(spacing: 15) {
                controlsHeader
                framerateControl
                whiteBalanceControl
                tintControl
            }
            .frame(maxWidth: .infinity)
            
            // Middle column - advanced controls
            VStack(spacing: 15) {
                isoControl
                shutterAngleDisplay
                lutControls
                exposureControls
                appleLogToggle
            }
            .frame(maxWidth: .infinity)
            
            // Right column - record button (always visible)
            VStack {
                Spacer()
                recordButton
                    .scaleEffect(1.2)
                Spacer()
            }
            .frame(maxWidth: 100, maxHeight: .infinity)
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
            
            // Make sure we respect device min/max limits for ISO
            let minIsoValue = viewModel.minISO
            let maxIsoValue = viewModel.maxISO
            
            Slider(value: $viewModel.iso, in: minIsoValue...maxIsoValue, step: 1) {
                Text("ISO")
            }
            .onChange(of: viewModel.iso) { _, newValue in
                // Extra safety check to ensure we're within device limits
                let clampedValue = min(max(viewModel.minISO, newValue), viewModel.maxISO)
                if clampedValue != newValue {
                    // If we need to clamp, update the value directly
                    DispatchQueue.main.async {
                        viewModel.iso = clampedValue
                    }
                } else {
                    // Only if within range, call the update method
                    viewModel.updateISO(newValue)
                }
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
        VStack(spacing: 5) {
            // LUT Loading button
            Button(action: {
                isShowingDocumentPicker = true
            }) {
                Label("Load LUT", systemImage: "photo.fill")
            }
            
            // Show LUT controls if a LUT is loaded
            if lutManager.currentLUTFilter != nil {
                VStack(spacing: 8) {
                    HStack {
                        // Show LUT name
                        Text(lutManager.currentLUTName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Spacer()
                        
                        // Clear LUT button
                        Button(action: {
                            lutManager.clearCurrentLUT()
                            viewModel.lutManager.currentLUTFilter = nil
                            viewModel.tempLUTFilter = nil
                            showLUTPreview = false
                            print("DEBUG: LUT cleared from all processing pipelines")
                        }) {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(.red)
                        }
                    }
                    
                    // Toggle LUT preview
                    Toggle(isOn: $showLUTPreview) {
                        Text("Preview LUT")
                            .font(.caption)
                    }
                    .onChange(of: showLUTPreview) { oldValue, newValue in
                        print("DEBUG: LUT preview toggled to \(newValue)")
                        
                        if newValue {
                            // When turning preview ON, ensure the LUT filter is active in the viewModel
                            if let lutFilter = lutManager.currentLUTFilter {
                                // First set the filter in the view model
                                viewModel.lutManager.currentLUTFilter = lutFilter
                                viewModel.tempLUTFilter = nil
                                print("DEBUG: Enabled LUT in viewModel pipeline")
                            } else if let tempFilter = viewModel.tempLUTFilter {
                                // If we have a stored temp filter, restore it
                                lutManager.currentLUTFilter = tempFilter
                                viewModel.lutManager.currentLUTFilter = tempFilter
                                viewModel.tempLUTFilter = nil
                                print("DEBUG: Restored LUT from temporary storage")
                            }
                        } else {
                            // When turning preview OFF, remove the LUT filter from processing
                            // but save it for later restoration
                            if viewModel.lutManager.currentLUTFilter != nil {
                                viewModel.tempLUTFilter = viewModel.lutManager.currentLUTFilter
                                
                                // Use a slight delay to ensure the overlay layer is properly removed
                                // before changing the filter reference
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    viewModel.lutManager.currentLUTFilter = nil
                                    print("DEBUG: Disabled LUT in viewModel pipeline but kept in temp storage")
                                }
                            }
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                }
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
            Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle.fill")
                .font(.system(size: uiOrientation.isPortrait ? 60 : 50))
                .foregroundColor(viewModel.isRecording ? .white : .red)
                .background(Circle().fill(viewModel.isRecording ? Color.red : Color.clear))
                .opacity(viewModel.isProcessingRecording ? 0.5 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(viewModel.isProcessingRecording)
    }
    
    private func handleLUTImport(url: URL) {
        // Import LUT file
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        print("LUT file size: \(fileSize) bytes")
        
        lutManager.importLUT(from: url) { success in
            if success {
                print("DEBUG: LUT import successful, enabling preview")
                
                // Enable the LUT in the viewModel for real-time preview
                if let lutFilter = self.lutManager.currentLUTFilter {
                    self.viewModel.lutManager.currentLUTFilter = lutFilter
                    self.showLUTPreview = true
                    print("DEBUG: LUT filter set in viewModel for preview")
                }
            } else {
                print("DEBUG: LUT import failed")
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