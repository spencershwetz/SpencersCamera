import SwiftUI
import AVFoundation
import CoreImage
import MetalKit
import Combine
import os.log

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel
    var onTap: ((CGPoint, Bool) -> Void)? = nil  // Added Bool parameter for lock state
    
    // Logger for CameraPreviewView (UIViewRepresentable part)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.spencerscamera", category: "CameraPreviewViewRepresentable")

    // ---> ADD INIT LOG <---
    init(session: AVCaptureSession, lutManager: LUTManager, viewModel: CameraViewModel, onTap: ((CGPoint, Bool) -> Void)? = nil) {
        self.session = session
        self.lutManager = lutManager
        self.viewModel = viewModel
        self.onTap = onTap
    }
    // ---> END INIT LOG <---

    func makeUIView(context: Context) -> MTKView {
        logger.debug("makeUIView: Creating MTKView")
        
        let mtkView = MTKView()
        mtkView.backgroundColor = .black // Set background
        mtkView.translatesAutoresizingMaskIntoConstraints = false

        // Create and assign the delegate with rotation support
        guard let metalDelegate = MetalPreviewView(mtkView: mtkView, lutManager: lutManager) else {
            logger.critical("Failed to create MetalPreviewView")
            return mtkView
        }
        // Force initial rotation to Portrait (90 degrees)
        metalDelegate.updateRotation(angle: 90)
        viewModel.metalPreviewDelegate = metalDelegate
        
        // Ensure initial layout
        mtkView.setNeedsLayout()
        mtkView.layoutIfNeeded()
        
        logger.info("makeUIView: MTKView and MetalPreviewView delegate created.")
        
        // Add tap gesture recognizer
        let tapRecognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mtkView.addGestureRecognizer(tapRecognizer)
        
        // Add long press gesture recognizer
        let longPressRecognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPressRecognizer.minimumPressDuration = 0.5
        mtkView.addGestureRecognizer(longPressRecognizer)
        
        // Store reference to parent for callback
        context.coordinator.onTap = onTap
        
        // Set up volume button handler
        viewModel.setPreviewView(mtkView)
        
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Only update if needed
    }
    
    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.parent.viewModel.removePreviewView()
    }
    
    func makeCoordinator() -> Coordinator {
        logger.info("makeCoordinator called.")
        return Coordinator(parent: self)
    }
    
    class Coordinator: NSObject {
        var parent: CameraPreviewView
        var onTap: ((CGPoint, Bool) -> Void)?
        private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraPreviewViewCoordinator")
        
        init(parent: CameraPreviewView) {
            self.parent = parent
            super.init()
            parent.logger.info("Coordinator initialized.")
        }
        
        @objc func handleTap(_ sender: UITapGestureRecognizer) {
            let location = sender.location(in: sender.view)
            print("📍 [CameraPreviewView.handleTap] Raw tap location in view: \(location)")
            print("📍 [CameraPreviewView.handleTap] View bounds: \(String(describing: sender.view?.bounds))")
            onTap?(location, false)  // false for regular tap (not locked)
        }
        
        @objc func handleLongPress(_ sender: UILongPressGestureRecognizer) {
            guard sender.state == .began else { return }
            let location = sender.location(in: sender.view)
            print("📍 [CameraPreviewView.handleLongPress] Raw long press location in view: \(location)")
            print("📍 [CameraPreviewView.handleLongPress] View bounds: \(String(describing: sender.view?.bounds))")
            onTap?(location, true)  // true for long press (locked)
        }
    }
}
