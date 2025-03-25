import SwiftUI
import CoreData
import CoreMedia
import UIKit

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()
    @StateObject private var lutManager = LUTManager()
    @State private var isShowingSettings = false
    @State private var isShowingDocumentPicker = false
    @State private var showLUTPreview = true
    @State private var isShowingVideoLibrary = false
    
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
                    
                    // Fixed position UI overlay (no rotation)
                    fixedUIOverlay()
                } else {
                    // Show loading or error state
                    VStack {
                        Text("Starting camera...")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        if viewModel.status == .failed, let error = viewModel.error {
                            Text("Error: \(error.description)")
                                .font(.subheadline)
                                .foregroundColor(.red)
                                .padding()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
            }
        }
        .onAppear {
            // Start the camera session when the view appears
            if !viewModel.session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async {
                    viewModel.session.startRunning()
                    DispatchQueue.main.async {
                        viewModel.isSessionRunning = viewModel.session.isRunning
                        viewModel.status = viewModel.session.isRunning ? .running : .failed
                        viewModel.error = viewModel.session.isRunning ? nil : CameraError.sessionFailedToStart
                        print("DEBUG: Camera session running: \(viewModel.isSessionRunning)")
                    }
                }
            }
            
            // Double enforce orientation lock on view appearance
            viewModel.updateInterfaceOrientation(lockCamera: true)
            
            // Setup notification for when app becomes active
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                print("DEBUG: App became active - re-enforcing camera orientation")
                viewModel.updateInterfaceOrientation(lockCamera: true)
            }
            
            // Share the lutManager between views
            viewModel.lutManager = lutManager
            
            // Enable LUT preview by default
            showLUTPreview = true
            
            // Enable device orientation notifications
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onDisappear {
            // Remove notification observer when the view disappears
            NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
            
            // Stop the camera session when the view disappears
            if viewModel.session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async {
                    viewModel.session.stopRunning()
                    DispatchQueue.main.async {
                        viewModel.isSessionRunning = false
                    }
                }
            }
            
            // Disable device orientation notifications
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .onChange(of: UIDevice.current.orientation) { oldValue, newValue in
            if newValue.isValidInterfaceOrientation {
                print("DEBUG: ContentView - Device orientation changed to \(newValue.rawValue)")
                
                // Always lock camera preview orientation to portrait
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
    
    // Fixed UI overlay that doesn't rotate
    private func fixedUIOverlay() -> some View {
        GeometryReader { geometry in
            VStack {
                Spacer()
                portraitControlsLayout
                    .padding(.horizontal, 20)
                    .padding(.bottom, 80) // Increased bottom padding for better visibility
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 300) // Moved higher up on screen
            }
        }
    }
    
    private var portraitControlsLayout: some View {
        VStack(spacing: 15) {
            controlsHeader
            videoLibraryButton
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
        .padding()
        .background(Color.black.opacity(0.5))
        .cornerRadius(15)
        .foregroundColor(.white)
    }
    
    private var controlsHeader: some View {
        Text("Camera Controls")
            .font(.headline)
    }
    
    private var videoLibraryButton: some View {
        Button(action: {
            // Set the flag in AppDelegate before showing the view
            print("DEBUG: [ORIENTATION-DEBUG] Setting AppDelegate.isVideoLibraryPresented = true")
            AppDelegate.isVideoLibraryPresented = true
            
            // Show the video library
            isShowingVideoLibrary = true
        }) {
            HStack {
                Image(systemName: "film")
                    .font(.system(size: 20))
                Text("Video Library")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.blue.opacity(0.6))
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .fullScreenCover(isPresented: $isShowingVideoLibrary, onDismiss: {
            // Reset any necessary state on dismiss
            print("DEBUG: Video library was dismissed")
        }) {
            VideoLibraryView()
                .preferredColorScheme(.dark)
        }
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
                .font(.system(size: 70)) // Increased size
                .foregroundColor(viewModel.isRecording ? .white : .red)
                .background(Circle().fill(viewModel.isRecording ? Color.red : Color.clear))
                .padding(10) // Add padding
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.4))
                        .shadow(color: .black.opacity(0.5), radius: 5)
                )
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
} 