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
    @State private var statusBarHidden = true
    
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
                // Background
                Color.black
                    .edgesIgnoringSafeArea(.all)
                
                // Camera preview with LUT
                cameraPreview
                    .edgesIgnoringSafeArea(.all)
                
                // Function buttons overlay
                FunctionButtonsView()
                    .zIndex(100) // Ensure it's above everything else
                    .allowsHitTesting(true) // Make sure buttons are tappable
                    .ignoresSafeArea()
                
                // Record button positioned at bottom with precise spacing
                VStack {
                    Spacer()
                    recordButton
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 30) // Approximately 1cm from USB-C port
                }
                .ignoresSafeArea()
                .zIndex(101) // Ensure it's above everything
                .background(
                    GeometryReader { buttonGeometry in
                        Color.clear.onAppear {
                            print("DEBUG: Root record button frame - \(buttonGeometry.frame(in: .global))")
                            print("DEBUG: Root screen size - width: \(geometry.size.width), height: \(geometry.size.height)")
                            print("DEBUG: Root safe area insets - \(geometry.safeAreaInsets)")
                        }
                    }
                )
            }
            .onAppear {
                print("DEBUG: CameraView appeared, size: \(geometry.size), safeArea: \(geometry.safeAreaInsets)")
                startSession()
            }
            .onDisappear {
                stopSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                // When app is moved to background
                stopSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                // When app returns to foreground
                startSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                // Get the current device orientation
                let deviceOrientation = UIDevice.current.orientation
                
                // Only update when the device orientation is a valid interface orientation
                if deviceOrientation.isValidInterfaceOrientation {
                    print("DEBUG: Device orientation changed to: \(deviceOrientation.rawValue)")
                    // Convert device orientation to interface orientation
                    let interfaceOrientation: UIInterfaceOrientation
                    switch deviceOrientation {
                    case .portrait:
                        interfaceOrientation = .portrait
                    case .portraitUpsideDown:
                        interfaceOrientation = .portraitUpsideDown
                    case .landscapeLeft:
                        interfaceOrientation = .landscapeRight // Note: these are flipped
                    case .landscapeRight:
                        interfaceOrientation = .landscapeLeft  // Note: these are flipped
                    default:
                        interfaceOrientation = .portrait
                    }
                    viewModel.updateOrientation(interfaceOrientation)
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
            .statusBar(hidden: statusBarHidden)
        }
    }
    
    private var cameraPreview: some View {
        GeometryReader { geometry in
            Group {
                if viewModel.isSessionRunning {
                    // Camera is running - show camera preview
                    CameraPreviewView(
                        session: viewModel.session,
                        lutManager: lutManager,
                        viewModel: viewModel
                    )
                    .ignoresSafeArea()
                    // Frame that starts below safe area and takes up 90% of the original size
                    .frame(
                        width: geometry.size.width * 0.9,
                        height: geometry.size.height * 0.75 * 0.9
                    )
                    .padding(.top, geometry.safeAreaInsets.top + 60) // Keep the same vertical position
                    .clipped() // Ensure the preview stays within bounds
                    .frame(maxWidth: .infinity) // Center the preview horizontally
                    
                    // Fixed position UI overlay (no rotation)
                    .overlay(fixedUIOverlay())
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
    }
    
    // Fixed UI overlay that doesn't rotate
    private func fixedUIOverlay() -> some View {
        GeometryReader { geometry in
            // Main controls only
            VStack {
                Spacer()
                portraitControlsLayout
                    .padding(.horizontal, 20)
                    .padding(.bottom, 80)
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 100)
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
            // Record button removed from here
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
            // Reset the flag when the view is dismissed
            print("DEBUG: [ORIENTATION-DEBUG] fullScreenCover onDismiss - setting AppDelegate.isVideoLibraryPresented = false")
            AppDelegate.isVideoLibraryPresented = false
            
            // Force back to portrait orientation using modern API
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                print("DEBUG: [ORIENTATION-DEBUG] Current orientation before reset: \(UIDevice.current.orientation.rawValue)")
                let orientations: UIInterfaceOrientationMask = [.portrait]
                let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
                
                print("DEBUG: Returning to portrait after video library")
                windowScene.requestGeometryUpdate(geometryPreferences) { error in
                    print("DEBUG: Portrait return result: \(error.localizedDescription)")
                    print("DEBUG: [ORIENTATION-DEBUG] Device orientation after portrait reset: \(UIDevice.current.orientation.rawValue)")
                }
                
                // Update all view controllers
                for window in windowScene.windows {
                    window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    print("DEBUG: [ORIENTATION-DEBUG] Updated orientation on root controller")
                }
                
                // Add a delay to let the device update its orientation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print("DEBUG: [ORIENTATION-DEBUG] Device orientation 0.5s after reset: \(UIDevice.current.orientation.rawValue)")
                }
            }
        }) {
            VideoLibraryView()
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
            withAnimation(.easeInOut(duration: 0.3)) {
                if viewModel.isRecording {
                    viewModel.stopRecording()
                } else {
                    viewModel.startRecording()
                }
            }
        }) {
            ZStack {
                // White border circle
                Circle()
                    .strokeBorder(Color.white, lineWidth: 4)
                    .frame(width: 75, height: 75)
                
                // Red recording indicator
                Group {
                    if viewModel.isRecording {
                        // Square when recording
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red)
                            .frame(width: 30, height: 30)
                    } else {
                        // Circle when not recording
                        Circle()
                            .fill(Color.red)
                            .frame(width: 54, height: 54)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel.isRecording)
            }
            .opacity(viewModel.isProcessingRecording ? 0.5 : 1.0)
        }
        .buttonStyle(ScaleButtonStyle()) // Custom button style for press animation
        .disabled(viewModel.isProcessingRecording)
    }
    
    // Custom button style for scale animation on press
    private struct ScaleButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
        }
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
    
    private func startSession() {
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
    
    private func stopSession() {
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
}

// Add preview at the bottom of the file
#Preview("Camera View") {
    CameraView()
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
}
