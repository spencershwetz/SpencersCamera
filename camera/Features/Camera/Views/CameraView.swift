import SwiftUI
import CoreData
import CoreMedia
import UIKit
import AVFoundation

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var orientation = UIDevice.current.orientation
    @StateObject private var lutManager = LUTManager()
    @State private var isShowingSettings = false
    @State private var isShowingDocumentPicker = false
    @State private var uiOrientation = UIDeviceOrientation.portrait
    @State private var showLUTPreview = true
    @State private var rotationAnimationDuration: Double = 0.3
    @State private var isRotating = false
    
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
        // Container that doesn't rotate
        ZStack {
            // Black background
            Color.black.ignoresSafeArea()
            
            // Create a frame with the correct aspect ratio regardless of orientation
            GeometryReader { outerGeometry in
                if viewModel.isSessionRunning {
                    // This ZStack contains all rotating content - it rotates as a single unit
                    ZStack {
                        // Fixed camera preview layer
                        FixedOrientationCameraPreview(session: viewModel.session, viewModel: viewModel)
                            .ignoresSafeArea()
                        
                        // UI overlay
                        CameraViewfinderOverlay(
                            viewModel: viewModel,
                            orientation: uiOrientation
                        )
                    }
                    // Apply rotation to the entire container
                    .rotationEffect(rotationAngle(for: uiOrientation))
                    // Use a container size appropriate for the orientation
                    .frame(
                        width: isLandscapeOrientation(uiOrientation) ? outerGeometry.size.height : outerGeometry.size.width,
                        height: isLandscapeOrientation(uiOrientation) ? outerGeometry.size.width : outerGeometry.size.height
                    )
                    .animation(.easeInOut(duration: rotationAnimationDuration), value: uiOrientation)
                    .opacity(isRotating ? 0.99 : 1.0)
                    // Center in the screen
                    .position(
                        x: outerGeometry.size.width / 2,
                        y: outerGeometry.size.height / 2
                    )
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
            
            // Lock camera orientation
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
                
                // Set rotating flag to true before animation starts
                isRotating = true
                
                // Use animation for smooth transition
                withAnimation(.easeInOut(duration: rotationAnimationDuration)) {
                    uiOrientation = newValue
                }
                
                // Always lock camera preview orientation
                viewModel.updateInterfaceOrientation(lockCamera: true)
                
                // Reset rotating flag after animation completes
                DispatchQueue.main.asyncAfter(deadline: .now() + rotationAnimationDuration) {
                    isRotating = false
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
    
    private func isLandscapeOrientation(_ orientation: UIDeviceOrientation) -> Bool {
        return orientation == .landscapeLeft || orientation == .landscapeRight
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