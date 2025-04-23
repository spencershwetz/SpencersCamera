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

    func makeUIView(context: Context) -> MTKView {
        logger.info("makeUIView: Creating MTKView")
        
        let mtkView = MTKView()
        mtkView.backgroundColor = .black // Set background
        mtkView.translatesAutoresizingMaskIntoConstraints = false

        // Create and assign the delegate, passing the lutManager
        let metalDelegate = MetalPreviewView(mtkView: mtkView, lutManager: lutManager)
        context.coordinator.metalDelegate = metalDelegate
        
        // Setup video output and store it on coordinator
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(context.coordinator, queue: DispatchQueue(label: "com.spencershwetz.spencerscamera.videoQueue"))
        context.coordinator.videoOutput = videoOutput  // Add storing of output reference
        
        // Configure video output settings
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        // Add output to session
        session.beginConfiguration()
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            
            // Ensure connection orientation is correct
            if let connection = videoOutput.connection(with: .video) {
                // Log connection info
                logger.info("PREVIEW_ORIENT: Connection videoRotationAngle: \(connection.videoRotationAngle)° (Should be 0)") // Verify it's 0
                logger.info("PREVIEW_ORIENT: Connection active: \(connection.isActive), enabled: \(connection.isEnabled)")
                logger.info("PREVIEW_ORIENT: Connection videoOrientation: \(connection.videoOrientation.rawValue)")
                logger.info("PREVIEW_ORIENT: Connection videoMirrored: \(connection.isVideoMirrored)")
            }
        } else {
            logger.error("Could not add video output to session")
        }
        session.commitConfiguration()
        
        // Ensure initial layout
        mtkView.setNeedsLayout()
        mtkView.layoutIfNeeded()
        
        logger.info("makeUIView: MTKView and MetalPreviewView delegate created.")
        return mtkView
    }
    
    /// Properly remove the preview output when the view is torn down
    func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        session.beginConfiguration()
        if let output = coordinator.videoOutput {
            session.removeOutput(output)
            logger.info("Removed preview videoOutput in dismantleUIView")
        }
        session.commitConfiguration()
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        logger.trace("updateUIView called.")
    }
    
    func makeCoordinator() -> Coordinator {
        logger.info("makeCoordinator called.")
        return Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        var parent: CameraPreviewView
        var metalDelegate: MetalPreviewView?
        var videoOutput: AVCaptureVideoDataOutput?  // Store reference for removal
        
        init(parent: CameraPreviewView) {
            self.parent = parent
            super.init()
            parent.logger.info("Coordinator initialized.")
        }
        
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            // Pass the frame to our Metal preview
            metalDelegate?.updateTexture(with: sampleBuffer)
        }
    }
}
