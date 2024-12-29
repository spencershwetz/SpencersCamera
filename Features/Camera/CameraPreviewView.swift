import CoreImage

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    
    class PreviewView: UIView {
        private let ciContext = CIContext()
        
        func processImage(_ sampleBuffer: CMSampleBuffer, lutFilter: CIFilter?) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            
            if let lutFilter = lutFilter {
                lutFilter.setValue(ciImage, forKey: kCIInputImageKey)
                if let outputImage = lutFilter.outputImage {
                    ciImage = outputImage
                }
            }
            
            // Update preview with processed image
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                DispatchQueue.main.async {
                    // Update preview layer with processed image
                    let layer = CALayer()
                    layer.contents = cgImage
                    layer.frame = self.bounds
                    self.layer.sublayers?.removeAll()
                    self.layer.addSublayer(layer)
                }
            }
        }
    }
    
    // Update makeUIView to handle video output
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspect
        
        // Add video output for LUT processing
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(context.coordinator, queue: DispatchQueue(label: "videoQueue"))
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        return view
    }
    
    // Add Coordinator for handling video frames
    class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let parent: CameraPreviewView
        
        init(_ parent: CameraPreviewView) {
            self.parent = parent
        }
        
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            if let view = parent.previewView as? PreviewView {
                view.processImage(sampleBuffer, lutFilter: parent.lutManager.currentLUT)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
} 