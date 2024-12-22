import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        
        view.layer.addSublayer(previewLayer)
        
        // Set rotation angle for portrait orientation (0 degrees)
        if #available(iOS 17.0, *) {
            previewLayer.connection?.videoRotationAngle = 0
        } else {
            previewLayer.connection?.videoOrientation = .portrait
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let layer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
                layer.frame = uiView.bounds
                
                // Maintain rotation angle
                if #available(iOS 17.0, *) {
                    layer.connection?.videoRotationAngle = 0
                } else {
                    layer.connection?.videoOrientation = .portrait
                }
            }
        }
    }
} 