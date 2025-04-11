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
    
    // Store the Metal delegate instance - make internal for initializer access
    var metalPreviewDelegate: MetalPreviewView?

    func makeUIView(context: Context) -> MTKView {
        logger.info("makeUIView: Creating MTKView")
        
        let mtkView = MTKView()
        mtkView.backgroundColor = .black // Set background
        mtkView.translatesAutoresizingMaskIntoConstraints = false

        // Create and assign the delegate
        // The delegate init handles Metal device/queue setup
        context.coordinator.metalDelegate = MetalPreviewView(mtkView: mtkView)
        
        // Pass necessary references TO the MetalPreviewView delegate if needed later
        // For now, it only needs the MTKView which is passed during init.
        
        // viewModel.owningView = mtkView // Maybe still needed? Re-evaluate later.
        
        // Ensure initial layout
        mtkView.setNeedsLayout()
        mtkView.layoutIfNeeded()
        
        logger.info("makeUIView: MTKView and MetalPreviewView delegate created.")
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        logger.trace("updateUIView called.")
        // Pass any necessary state updates to the Metal delegate if needed
        // e.g., context.coordinator.metalDelegate?.updateLUT(lutManager.currentLUTTexture) // For later steps
    }
    
    func makeCoordinator() -> Coordinator {
        logger.info("makeCoordinator called.")
        return Coordinator(parent: self)
    }
    
    class Coordinator: NSObject {
        var parent: CameraPreviewView
        var metalDelegate: MetalPreviewView? // Store the Metal delegate
        
        init(parent: CameraPreviewView) {
            self.parent = parent
            super.init()
            parent.logger.info("Coordinator initialized.")
        }
    }
}
