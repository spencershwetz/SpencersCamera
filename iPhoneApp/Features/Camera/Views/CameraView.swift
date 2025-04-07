import SwiftUI
import CoreData
import CoreMedia
import UIKit
import AVFoundation

struct CameraView: View {
    @StateObject private var viewModel: CameraViewModel
    @EnvironmentObject var settings: SettingsModel
    @EnvironmentObject var orientationManager: OrientationManager

    // Use the shared instance with @ObservedObject
    @ObservedObject private var orientationViewModel = DeviceOrientationViewModel.shared

    @State private var isShowingSettings = false
    @State private var isShowingDocumentPicker = false
    @State private var showLUTPreview = true
    @State private var isShowingVideoLibrary = false
    @State private var statusBarHidden = true
    @State private var isDebugEnabled = false
    
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
            // Call the function to set the orientation lock when the app becomes active
            // Directly access the shared instance to avoid environment object issues in closure
            OrientationManager.shared.updateOrientationMask(.portrait)
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // Background
                Color.black
                    // REMOVED: .edgesIgnoringSafeArea(.all) <- This caused GeometryReader to ignore safe area
                
                // Log geometry before calling cameraPreview
                let _ = print("CameraView Geometry - Size: \(geometry.size), Top Safe Area: \(geometry.safeAreaInsets.top)")
                
                // Camera preview with LUT
                cameraPreview(geometry: geometry)
                
                // Function buttons overlay
                FunctionButtonsView(viewModel: viewModel, isShowingSettings: $isShowingSettings, isShowingLibrary: $isShowingVideoLibrary)
                    .zIndex(100)
                    .allowsHitTesting(true)
                    .ignoresSafeArea()
                
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
                // Set the orientation lock when the view appears
                setCameraOrientationLock()
                startSession()
            }
            .onDisappear {
                // Unlock orientation when leaving the camera view - REMOVED as it conflicts with modal dismissals
                // orientationManager.updateOrientationMask(.all)
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
            .alert(item: $viewModel.error) { error in
                Alert(
                    title: Text("Error"),
                    message: Text(error.description),
                    dismissButton: .default(Text("OK"))
                )
            }
            .fullScreenCover(isPresented: $isShowingSettings, onDismiss: {
                // ADDED: Reset orientation lock when settings is dismissed
                orientationManager.updateOrientationMask(.portrait)
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
    
    private func cameraPreview(geometry: GeometryProxy) -> some View {
        // Log calculated frame size
        let previewWidth = geometry.size.width * 0.9
        let previewHeight = geometry.size.height * 0.75 * 0.9
        let _ = print("CameraPreview Calculated Frame - Width: \(previewWidth), Height: \(previewHeight)")
        
        return Group {
            if viewModel.isSessionRunning {
                // Check if previewVideoOutput is available before creating the view
                if let previewOutput = viewModel.previewVideoOutput {
                    MetalCameraPreviewView(session: viewModel.session, 
                                           viewModel: viewModel, 
                                           lutManager: viewModel.lutManager, 
                                           previewVideoOutput: previewOutput) // Pass the output
                        .ignoresSafeArea()
                        .frame(
                            width: previewWidth,
                            height: previewHeight
                        )
                        .clipped()
                        .frame(maxWidth: .infinity)
                        // Removed top padding to allow preview to go to the top edge
                        .overlay(alignment: .topLeading) {
                            if isDebugEnabled {
                                debugOverlay
                                    .padding(.top, 60)
                                    .padding(.leading, 20)
                            }
                        }
                } else {
                    // Show an error or loading state if the preview output isn't ready
                    VStack {
                        Text("Camera Error")
                            .font(.headline)
                            .foregroundColor(.red)
                        Text("Preview output unavailable.")
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
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
    
    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Resolution: \(viewModel.selectedResolution.rawValue)")
            Text("FPS: \(String(format: "%.2f", viewModel.selectedFrameRate))")
            Text("Codec: \(viewModel.selectedCodec.rawValue)")
            Text("Color: \(viewModel.isAppleLogEnabled ? "Apple Log" : "Rec.709")")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundColor(.white)
        .padding(6)
        .background(Color.black.opacity(0.5))
        .cornerRadius(6)
    }
    
    private var videoLibraryButton: some View {
        Button {
            // UPDATE: Use OrientationManager to allow landscape
            orientationManager.updateOrientationMask(.all)
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
            // UPDATE: Use OrientationManager to reset to portrait
            orientationManager.updateOrientationMask(.portrait)
            // REMOVED: Old code resetting AppDelegate flag and forcing geometry update
            /*
            print("DEBUG: [ORIENTATION-DEBUG] library fullScreenCover onDismiss scheduled - setting AppDelegate.isVideoLibraryPresented = false")
            AppDelegate.isVideoLibraryPresented = false // Lock back to portrait

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
             */
        }) {
            VideoLibraryView(dismissAction: { isShowingVideoLibrary = false })
        }
    }
    
    private var settingsButton: some View {
        Button(action: {
            // UPDATE: Use OrientationManager to allow landscape
            orientationManager.updateOrientationMask(.all)
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
        .rotateWithDeviceOrientation(using: orientationViewModel)
        .frame(width: 60, height: 60)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 3.0)
                .onEnded { _ in
                    withAnimation {
                        isDebugEnabled.toggle()
                    }
                }
        )
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
                    // Ensure default orientation is set when session starts
                    orientationManager.updateOrientationMask(.portrait)
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
        // Reset orientation when session stops
        orientationManager.updateOrientationMask(.portrait)
    }

    // Function to set the camera view's orientation lock
    private func setCameraOrientationLock() {
        orientationManager.updateOrientationMask(.portrait)
    }
}

// Add preview at the bottom of the file
#Preview("Camera View") {
    CameraView(viewModel: CameraViewModel())
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
}
