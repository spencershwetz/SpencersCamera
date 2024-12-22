import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        
        view.layer.addSublayer(previewLayer)
        
        // Initial orientation setup
        updatePreviewLayerOrientation(previewLayer)
        
        // Add orientation change observer
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main) { _ in
                updatePreviewLayerOrientation(previewLayer)
            }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let layer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
                layer.frame = uiView.bounds
                updatePreviewLayerOrientation(layer)
            }
        }
    }
    
    private func updatePreviewLayerOrientation(_ layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection else { return }
        
        // For now, we'll just handle portrait mode
        if #available(iOS 17.0, *) {
            connection.videoRotationAngle = 90 // Changed from 270 to 90 degrees for portrait
        } else {
            connection.videoOrientation = .portrait
        }
    }
} 