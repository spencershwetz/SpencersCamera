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
        
        // Set up video output
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(context.coordinator, queue: DispatchQueue(label: "com.spencershwetz.spencerscamera.videoQueue"))
        
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
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                    logger.info("Set video rotation angle to 90°")
                }
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
