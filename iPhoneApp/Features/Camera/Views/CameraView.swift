import SwiftUI
import CoreData
import CoreMedia
import UIKit
import AVFoundation
import os.log // Import os.log
import CoreLocation

// Add import for the new picker's directory if needed (adjust path if necessary)
// import AppName.UI.CommonViews // Or similar depending on your project structure

struct CameraView: View {
    @StateObject private var viewModel: CameraViewModel
    @EnvironmentObject var settings: SettingsModel
    @Environment(\.scenePhase) private var scenePhase

    // Use the shared instance with @ObservedObject
    @ObservedObject private var orientationViewModel = DeviceOrientationViewModel.shared

    @State private var isShowingSettings = false
    @State private var isShowingDocumentPicker = false
    @State private var showLUTPreview = true
    @State private var isShowingVideoLibrary = false
    @State private var statusBarHidden = true
    @State private var focusSquarePosition: CGPoint? = nil
    @State private var lastFocusPoint: CGPoint? = nil // Normalized 0-1 point
    @State private var showExposureSlider: Bool = true
    @State private var lastTapLocation: CGPoint = .zero
    @State private var isFocusLocked: Bool = false
    
    // State for the temporary SimpleWheelPicker test - REMOVED
    // @State private var testWheelValue: CGFloat = 0
    // @State private var testWheelConfig: SimpleWheelPicker.Config = .init(count: 20, steps: 5, spacing: 8, multiplier: 1, showsText: true)

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraView")

    // Initialize with proper handling of StateObjects
    init(viewModel: CameraViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        // We CANNOT access @StateObject properties here as they won't be initialized yet
        // Only setup notifications that don't depend on StateObjects
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
            }
            .onDisappear {
                viewModel.stopSession()
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                switch newPhase {
                case .active:
                    print("DEBUG: ScenePhase changed to active, calling viewModel.startSession()")
                    viewModel.startSession()
                case .inactive:
                    print("DEBUG: ScenePhase changed to inactive, calling viewModel.stopSession()")
                    viewModel.stopSession()
                case .background:
                    print("DEBUG: ScenePhase changed to background, calling viewModel.stopSession()")
                    viewModel.stopSession()
                @unknown default:
                    // Handle future cases if necessary
                    print("DEBUG: ScenePhase changed to unknown state.")
                    viewModel.stopSession() // Stop session as a safe default
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
                    settingsModel: settings,
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
                #if DEBUG
                // Check if running in Xcode Preview environment
                if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
                    let _ = print("DEBUG: Running in Xcode Preview, showing placeholder.")
                    // Always show placeholder in Xcode Previews
                    PlaceholderCameraPreview()
                         .padding(.top, geometry.safeAreaInsets.top + 10) // Apply similar padding
                         .frame(maxWidth: .infinity)
                } else {
                    // Running on actual device or simulator, use live preview logic
                    liveCameraPreview(geometry: geometry)
                }
                #else
                // In release builds, always use live preview logic
                liveCameraPreview(geometry: geometry)
                #endif
            }
        }
    }
    
    // Helper function extracted to avoid duplication
    @ViewBuilder
    private func liveCameraPreview(geometry: GeometryProxy) -> some View {
        // Keep CameraPreviewView always in the hierarchy
        CameraPreviewView(
            session: viewModel.session,
            lutManager: viewModel.lutManager,
            viewModel: viewModel,
            onTap: { tapLocation, isLongPress in
                lastTapLocation = tapLocation
                let point = locationInPreview(tapLocation, geometry: geometry)
                
                if isLongPress {
                    // Long press always sets focus and locks
                    isFocusLocked = true
                    focus(at: point, lock: true)
                } else {
                    // Regular tap always sets continuous auto-focus
                    isFocusLocked = false
                    focus(at: point, lock: false)
                }
            }
        )
        .aspectRatio(9.0/16.0, contentMode: .fit)
        .scaleEffect(0.9)
        .clipped()
        .padding(.top, geometry.safeAreaInsets.top + 10)
        .frame(maxWidth: .infinity)
        
        .overlay(
            focusSquare
        )
        .overlay(
            Group {
                if showExposureSlider {
                    VStack { 
                        // --- Use SimpleWheelPicker for Exposure Bias ---
                        // Create a Binding<CGFloat> that converts to/from Binding<Float>
                        let exposureBiasBinding = Binding<CGFloat>(
                            get: { CGFloat(viewModel.exposureBias) },
                            set: { viewModel.exposureBias = Float($0) }
                        )
                        
                        SimpleWheelPicker(
                            config: .init(
                                min: CGFloat(viewModel.minExposureBias), // Convert Float to CGFloat
                                max: CGFloat(viewModel.maxExposureBias), // Convert Float to CGFloat
                                stepsPerUnit: 10, 
                                spacing: 8,       
                                showsText: true
                            ),
                            value: exposureBiasBinding // Use the CGFloat binding
                        )
                        .frame(height: 60)
                        .background(Color.black.opacity(0.5)) // Use a less intrusive background
                        .padding(.horizontal, 0) // Use padding from VStack instead
                        
                        // Display current EV value below the picker
                        Text(String(format: "%+.1f EV", viewModel.exposureBias))
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.bottom, 5)
                        // ----------------------------------------------

                        // --- SimpleWheelPicker for Haptic Test --- - REMOVED
                        /*
                        Divider().background(Color.white)
                        Text("Test Wheel: \(testWheelValue, specifier: "%.1f")")
                            .foregroundColor(.white)
                            .font(.caption)
                        SimpleWheelPicker(config: testWheelConfig, value: $testWheelValue)
                            .frame(height: 60)
                            .background(Color.red.opacity(0.3)) // Make it visible
                        */
                        // ---------------------------------
                    }
                    .padding(.trailing, 10) 
                    .transition(.opacity) 
                    .zIndex(200) // Ensure it appears above other overlays
                    .onChange(of: viewModel.exposureBias) { _, newValue in
                        viewModel.setExposureBias(newValue)
                    }
                }
            }
            .animation(.easeInOut, value: showExposureSlider),
            alignment: .trailing // Align the overlay to the trailing edge
        )
        // Add swipe gesture to the preview area
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onEnded { value in
                    // Detect vertical swipes primarily
                    let horizontalAmount = value.translation.width
                    let verticalAmount = value.translation.height
                    logger.debug("[SwipeGesture] Ended: H=\(horizontalAmount, format: .fixed(precision: 1)), V=\(verticalAmount, format: .fixed(precision: 1))")
                    
                    // Check if vertical movement is greater than horizontal movement
                    let isVerticalSwipe = abs(verticalAmount) > abs(horizontalAmount)
                    logger.debug("[SwipeGesture] Is Vertical Swipe? \(isVerticalSwipe)")
                    
                    if isVerticalSwipe {
                        if verticalAmount < -40 { // Swipe Up
                            logger.debug("[SwipeGesture] Detected Swipe Up. Showing EV slider.")
                            // Swipe up: show slider
                            showExposureSlider = true
                        } else if verticalAmount > 40 { // Swipe Down
                            logger.debug("[SwipeGesture] Detected Swipe Down. Hiding EV slider.")
                            // Swipe down: hide slider
                            showExposureSlider = false
                        } else {
                            logger.debug("[SwipeGesture] Vertical swipe detected, but below threshold (40). No action.")
                        }
                    } else {
                        logger.debug("[SwipeGesture] Horizontal swipe detected or movement too small. No action.")
                    }
                }
        )
        .overlay(alignment: .topLeading) {
            if settings.isDebugEnabled {
                debugOverlay
                    .padding(.top, geometry.safeAreaInsets.top + 70) // Adjust padding if needed due to aspect ratio
                    .padding(.leading, 20)
            }
        }
        .overlay {
            // Overlay a placeholder or loading indicator if the session is not running
            if !viewModel.isSessionRunning {
                ZStack {
                    Color.black // Background for the placeholder text
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
                }
                .transition(.opacity) // Optional animation
            }
        }
    }
    
    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Resolution: \(viewModel.selectedResolution.rawValue)")
            Text("FPS: \(String(format: "%.2f", viewModel.selectedFrameRate))")
            Text("Codec: \(viewModel.selectedCodec.rawValue)")
            Text("ISO: \(String(format: "%.0f", viewModel.iso))")
            Text("WB: \(String(format: "%.0fK", viewModel.whiteBalance))")
            Text("Tint: \(String(format: "%.1f", viewModel.currentTint))")
            Text("Shutter: \(formatShutterSpeed(viewModel.shutterSpeed))")
            Text("EV Bias: \(String(format: "%.1f", viewModel.exposureBias))")
            
            // Check the actual activeColorSpace from the device to display the correct value
            if let device = viewModel.currentCameraDevice {
                let actualColorSpace = device.activeColorSpace
                if actualColorSpace == .appleLog {
                    Text("Color: Apple Log 📱")
                } else {
                    Text("Color: Rec.709 🎬")
                }
            } else {
                Text("Color: \(viewModel.isAppleLogEnabled ? "Apple Log" : "Rec.709")")
            }
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
                            settings.isDebugEnabled.toggle()
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
    
    // Helper method to format shutter speed for display
    private func formatShutterSpeed(_ time: CMTime) -> String {
        let seconds = time.seconds
        let angle = seconds * viewModel.selectedFrameRate * 360
        
        if seconds < 1.0/60.0 {
            return String(format: "1/%.0f (%.0f°)", 1.0/seconds, angle)
        } else {
            return String(format: "%.2fs (%.0f°)", seconds, angle)
        }
    }
    
    // MARK: - Focus & Exposure Helpers
    private func focus(at point: CGPoint, lock: Bool) {
        print("📍 [CameraView.focus] Called with point: \(point), lock: \(lock), isFocusLocked: \(isFocusLocked)")
        viewModel.focus(at: point, lockAfter: lock)
        lastFocusPoint = point
        focusSquarePosition = CGPoint(x: lastTapLocation.x, y: lastTapLocation.y)
        
        // Hide square after delay only if not locked
        if !lock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !self.isFocusLocked {  // Only hide if not locked
                    focusSquarePosition = nil
                }
            }
        }
    }

    private func locationInPreview(_ location: CGPoint, geometry: GeometryProxy) -> CGPoint {
        print("📍 [CameraView.locationInPreview] Raw tap location: \(location)")
        // Get the preview frame
        let previewFrame = geometry.frame(in: .local)
        print("📍 [CameraView.locationInPreview] Preview frame: \(previewFrame)")
        
        // Account for the 0.9 scale effect and top padding
        let scaledWidth = previewFrame.width * 0.9
        let scaledHeight = previewFrame.height * 0.9
        let topPadding = geometry.safeAreaInsets.top + 10
        print("📍 [CameraView.locationInPreview] Scaled dimensions - width: \(scaledWidth), height: \(scaledHeight), topPadding: \(topPadding)")
        
        // Calculate the actual preview bounds
        let previewBounds = CGRect(
            x: (previewFrame.width - scaledWidth) / 2,
            y: topPadding,
            width: scaledWidth,
            height: scaledHeight
        )
        print("📍 [CameraView.locationInPreview] Calculated preview bounds: \(previewBounds)")
        
        // Convert tap location to normalized coordinates (0-1)
        let x = (location.x - previewBounds.minX) / previewBounds.width
        let y = (location.y - previewBounds.minY) / previewBounds.height
        print("📍 [CameraView.locationInPreview] Pre-clamp normalized coordinates - x: \(x), y: \(y)")
        
        // Clamp to valid range [0,1]
        let normalizedPoint = CGPoint(
            x: min(max(0, x), 1),
            y: min(max(0, y), 1)
        )
        print("📍 [CameraView.locationInPreview] Final normalized point: \(normalizedPoint)")
        return normalizedPoint
    }

    private var focusSquare: some View {
        Group {
            if let position = focusSquarePosition {
                FocusSquare(isLocked: isFocusLocked)
                    .position(position)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct CameraView_Previews: PreviewProvider {
    static var previews: some View {
        // Create a dummy/mock SettingsModel for the preview
        let mockSettings = SettingsModel()
        
        // Create a CameraViewModel instance JUST for the preview.
        // IMPORTANT: This still runs the CameraViewModel init logic, which tries
        // to set up the camera. For a truly isolated preview, you'd create a
        // MockCameraViewModel protocol/class that doesn't touch AVCaptureSession.
        // However, for just displaying the UI structure, this might be sufficient,
        // although the preview might still log errors from the ViewModel init.
        let previewViewModel = CameraViewModel(settingsModel: mockSettings)

        // Inject a mock SettingsModel into the environment for the preview
        CameraView(viewModel: previewViewModel)
            .environmentObject(mockSettings) // Provide the mock SettingsModel
            .preferredColorScheme(.dark) // Example: force dark mode for preview
            .onAppear {
                 // Optionally simulate states for previewing UI elements
                 // previewViewModel.isSessionRunning = false // Simulate loading state
                 // previewViewModel.error = CameraError.cameraUnavailable // Simulate error state
                 // previewViewModel.isRecording = true // Simulate recording state
            }
    }
}

// Simple placeholder for the camera feed in previews if CameraPreviewView causes issues
struct PlaceholderCameraPreview: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary) // Use a gray color
            .aspectRatio(9.0/16.0, contentMode: .fit)
            .scaleEffect(0.9)
            .clipped()
            .overlay(Text("Camera Preview").foregroundColor(.white))
    }
}
#endif
