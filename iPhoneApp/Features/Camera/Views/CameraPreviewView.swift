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
    
    // Logger for CameraPreviewView (UIViewRepresentable part)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraPreviewViewRepresentable")

    // ---> ADD INIT LOG <---
    init(session: AVCaptureSession, lutManager: LUTManager, viewModel: CameraViewModel) {
        self.session = session
        self.lutManager = lutManager
        self.viewModel = viewModel
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
        
        init(parent: CameraPreviewView) {
            self.parent = parent
            super.init()
            parent.logger.info("Coordinator initialized.")
        }
    }
}
