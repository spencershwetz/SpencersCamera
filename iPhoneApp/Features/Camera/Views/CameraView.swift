import SwiftUI
import CoreData
import CoreMedia
import UIKit
import AVFoundation

struct CameraView: View {
    @StateObject private var viewModel: CameraViewModel
    @EnvironmentObject var settings: SettingsModel

    // Use the shared instance with @ObservedObject
    @ObservedObject private var orientationViewModel = DeviceOrientationViewModel.shared

    @State private var isShowingSettings = false
    @State private var isShowingDocumentPicker = false
    @State private var showLUTPreview = true
    @State private var isShowingVideoLibrary = false
    @State private var statusBarHidden = true
    @State private var isDebugEnabled = true
    
    // Initialize with proper handling of StateObjects
    init(viewModel: CameraViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
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
                FunctionButtonsView(viewModel: viewModel, settingsModel: settings, isShowingSettings: $isShowingSettings, isShowingLibrary: $isShowingVideoLibrary)
                    .zIndex(100)
                    .allowsHitTesting(true)
                
                // Lens selection with zoom slider
                VStack {
                    Spacer()
                        .frame(height: geometry.safeAreaInsets.top + geometry.size.height * 0.75)
                    
                    if !viewModel.availableLenses.isEmpty {
                        ZoomSliderView(viewModel: viewModel, availableLenses: viewModel.availableLenses)
                            .padding(.bottom, 20)
                    }
                    
                    Spacer()
                }
                .zIndex(99)
                
                // Bottom controls container
                VStack {
                    Spacer()
                    ZStack {
                        // Center record button
                        recordButton
                            .frame(width: 75, height: 75)
                        
                        // Position library button on the left and settings button on the right
                        HStack {
                            videoLibraryButton
                                .frame(width: 60, height: 60)
                                .disabled(viewModel.isRecording)
                            Spacer()
                            settingsButton
                                .frame(width: 60, height: 60)
                                .disabled(viewModel.isRecording)
                        }
                        .padding(.horizontal, 67.5) // Half the record button width (75/2) + button width (60)
                    }
                    .padding(.bottom, 30) // Approximately 1cm from USB-C port
                }
                .ignoresSafeArea()
                .zIndex(101)
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
            .onChange(of: viewModel.lutManager.currentLUTFilter) { oldValue, newValue in
                // When LUT changes, update preview indicator
                if newValue != nil {
                    print("DEBUG: LUT filter updated to: \(viewModel.lutManager.currentLUTName)")
                    // Automatically turn on preview when a new LUT is loaded
                    showLUTPreview = true
                } else {
                    print("DEBUG: LUT filter removed")
                }
            }
            .onChange(of: viewModel.currentLens) { oldValue, newValue in
                // When lens changes, ensure LUT overlay maintains correct orientation
                // REMOVED: Old logic accessing CustomPreviewView via tag
                /*
                if showLUTPreview && viewModel.lutManager.currentLUTFilter != nil {
                    // Access the preview view and update its LUT overlay orientation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if let container = viewModel.owningView,
                           let preview = container.viewWithTag(100) as? CameraPreviewView.CustomPreviewView {
                            preview.updateLUTOverlayOrientation()
                            print("DEBUG: Updated LUT overlay orientation after lens change")
                        }
                    }
                }
                */
            }
            .alert(item: $viewModel.error) { error in
                Alert(
                    title: Text("Error"),
                    message: Text(error.description),
                    dismissButton: .default(Text("OK"))
                )
            }
            .fullScreenCover(isPresented: $isShowingSettings, onDismiss: {
                // Reset orientation lock when settings is dismissed
                print("DEBUG: [ORIENTATION-DEBUG] settings fullScreenCover onDismiss - setting AppDelegate.isVideoLibraryPresented = false")
            }) {
                SettingsView(
                    lutManager: viewModel.lutManager,
                    viewModel: viewModel,
                    isDebugEnabled: $isDebugEnabled,
                    dismissAction: { isShowingSettings = false }
                )
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
                        lutManager: viewModel.lutManager,
                        viewModel: viewModel
                    )
                    .ignoresSafeArea()
                    .frame(
                        width: geometry.size.width * 0.9,
                        height: geometry.size.height * 0.75 * 0.9
                    )
                    .padding(.top, geometry.safeAreaInsets.top + 60)
                    .clipped()
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topLeading) {
                        if isDebugEnabled {
                            debugOverlay
                                .padding(.top, geometry.safeAreaInsets.top + 70)
                                .padding(.leading, 20)
                        }
                    }
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
    
    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Resolution: \(viewModel.selectedResolution.rawValue)")
            Text("FPS: \(String(format: "%.2f", viewModel.selectedFrameRate))")
            Text("Codec: \(viewModel.selectedCodec.rawValue)")
            Text("Color: \(viewModel.isAppleLogEnabled ? "Apple Log" : "Rec.709")")
            Text("ISO: \(Int(viewModel.iso))")
            Text("WB: \(Int(viewModel.whiteBalance))K")
            Text("Tint: \(String(format: "%.1f", viewModel.currentTint))")
            Text("Shutter Angle: \(String(format: "%.0f°", viewModel.shutterSpeed.seconds * viewModel.selectedFrameRate * 360))")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundColor(.white)
        .padding(6)
        .background(Color.black.opacity(0.5))
        .cornerRadius(6)
    }
    
    private var videoLibraryButton: some View {
        Button {
            print("DEBUG: [ORIENTATION-DEBUG] Library button tapped - setting AppDelegate.isVideoLibraryPresented = true")
            isShowingVideoLibrary = true
        } label: {
            Image(systemName: "photo.stack")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(15)
                .frame(width: 60, height: 60)
                .background(Color.gray.opacity(0.3))
                .clipShape(Circle())
                .foregroundColor(.white)
        }
        .fullScreenCover(isPresented: $isShowingVideoLibrary, onDismiss: {
            print("DEBUG: [ORIENTATION-DEBUG] library fullScreenCover onDismiss scheduled - setting AppDelegate.isVideoLibraryPresented = false")

            // Delay orientation change to allow dismissal animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // Add 0.5 second delay
                 print("DEBUG: [ORIENTATION-DEBUG] Executing delayed onDismiss logic for library")
                 // Re-apply portrait lock when dismissing library
                 if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                     let orientations: UIInterfaceOrientationMask = [.portrait]
                     let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
                     
                     print("DEBUG: Returning to portrait after library (delayed)")
                     windowScene.requestGeometryUpdate(geometryPreferences) { error in
                         print("DEBUG: Portrait return result: \(error.localizedDescription)")
                     }
                     
                     for window in windowScene.windows {
                         window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                     }
                 }
             }
        }) {
            // Allow landscape mode within the library view
            OrientationFixView(allowsLandscapeMode: true) {
                VideoLibraryView(dismissAction: { isShowingVideoLibrary = false })
            }
        }
    }
    
    private var settingsButton: some View {
        RotatingView(orientationViewModel: orientationViewModel) {
            Button(action: {
                isShowingSettings = true
            }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.6))
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 3.0)
                    .onEnded { _ in
                        withAnimation {
                            isDebugEnabled.toggle()
                        }
                    }
            )
        }
    }
    
    private var recordButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.3)) {
                _ = Task { @MainActor in
                    if viewModel.isRecording {
                        await viewModel.stopRecording()
                    } else {
                        await viewModel.startRecording()
                    }
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
        
        viewModel.lutManager.importLUT(from: url) { success in
            if success {
                print("DEBUG: LUT import successful, enabling preview")
                
                // Enable the LUT in the viewModel for real-time preview
                if let lutFilter = self.viewModel.lutManager.currentLUTFilter {
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
    CameraView(viewModel: CameraViewModel())
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
}
