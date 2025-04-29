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
    var onTap: ((CGPoint) -> Void)? = nil
    
    // Logger for CameraPreviewView (UIViewRepresentable part)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraPreviewViewRepresentable")

    // ---> ADD INIT LOG <---
    init(session: AVCaptureSession, lutManager: LUTManager, viewModel: CameraViewModel, onTap: ((CGPoint) -> Void)? = nil) {
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
        let metalDelegate = MetalPreviewView(mtkView: mtkView, lutManager: lutManager)
        // Force initial rotation to Portrait (90 degrees)
        metalDelegate.updateRotation(angle: 90)
        viewModel.metalPreviewDelegate = metalDelegate
        
        // Ensure initial layout
        mtkView.setNeedsLayout()
        mtkView.layoutIfNeeded()
        
        logger.info("makeUIView: MTKView and MetalPreviewView delegate created.")
        
        // Attach native tap gesture recognizer
        let tapRecognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mtkView.addGestureRecognizer(tapRecognizer)
        
        // Store reference to parent for callback
        context.coordinator.onTap = onTap
        
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Only update if needed
    }
    
    func makeCoordinator() -> Coordinator {
        logger.info("makeCoordinator called.")
        return Coordinator(parent: self)
    }
    
    class Coordinator: NSObject {
        var parent: CameraPreviewView
        var onTap: ((CGPoint) -> Void)?
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
            onTap?(location)
        }
    }
}
