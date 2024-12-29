import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let lutManager: LUTManager
    let viewModel: CameraViewModel
    
    class PreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }
        
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
        
        var videoOutput: AVCaptureVideoDataOutput?
        
        func setupVideoOutput(session: AVCaptureSession, delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
            // Remove any existing output
            if let existingOutput = videoOutput {
                session.removeOutput(existingOutput)
            }
            
            // Create and configure video output
            let output = AVCaptureVideoDataOutput()
            output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "videoQueue"))
            
            if session.canAddOutput(output) {
                session.addOutput(output)
                videoOutput = output
                print("✅ Video output added to session")
            } else {
                print("❌ Could not add video output to session")
            }
        }
    }
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspect
        
        // Create and set up video output delegate
        let videoDelegate = VideoOutputDelegate(lutManager: lutManager, viewModel: viewModel)
        view.setupVideoOutput(session: session, delegate: videoDelegate)
        
        // Initial orientation setup
        updatePreviewLayerOrientation(view.videoPreviewLayer)
        
        // Add orientation change observer
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main) { _ in
                updatePreviewLayerOrientation(view.videoPreviewLayer)
            }
        
        return view
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        updatePreviewLayerOrientation(uiView.videoPreviewLayer)
        CATransaction.commit()
    }
    
    private func updatePreviewLayerOrientation(_ layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection else { return }
        
        let currentDevice = UIDevice.current
        let orientation = currentDevice.orientation
        
        if #available(iOS 17.0, *) {
            switch orientation {
            case .portrait:
                connection.videoRotationAngle = 90
            case .landscapeRight: // Device rotated left
                connection.videoRotationAngle = 180
            case .landscapeLeft: // Device rotated right
                connection.videoRotationAngle = 0
            case .portraitUpsideDown:
                connection.videoRotationAngle = 270
            default:
                connection.videoRotationAngle = 90
            }
        } else {
            switch orientation {
            case .portrait:
                connection.videoOrientation = .portrait
            case .landscapeRight: // Device rotated left
                connection.videoOrientation = .landscapeLeft
            case .landscapeLeft: // Device rotated right
                connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown:
                connection.videoOrientation = .portraitUpsideDown
            default:
                connection.videoOrientation = .portrait
            }
        }
    }
    
    // Add this method to track image processing
    private func processImage(_ image: CIImage) -> CIImage {
        var processedImage = image
        
        // Log the initial state
        print("🎥 Processing image pipeline:")
        print("  - Input image: \(image)")
        
        if viewModel.isAppleLogEnabled {
            print("  - Apple Log enabled, converting...")
            // Apple Log processing here
        }
        
        // Check if LUT should be applied and apply it
        if lutManager.currentLUTFilter != nil {
            print("  - Applying LUT filter...")
            if let lutImage = lutManager.applyLUT(to: processedImage) {
                processedImage = lutImage
                print("  ✅ LUT applied successfully")
            } else {
                print("  ❌ Failed to apply LUT")
            }
        } else {
            print("  ℹ️ No LUT filter active")
        }
        
        print("  - Final output image: \(processedImage)")
        return processedImage
    }
} 