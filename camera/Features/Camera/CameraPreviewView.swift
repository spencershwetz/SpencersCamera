import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    class PreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }
        
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
    }
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspect
        
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
} 