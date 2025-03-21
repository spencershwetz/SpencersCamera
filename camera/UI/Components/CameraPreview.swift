import SwiftUI
import AVFoundation

struct FixedOrientationCameraPreview: UIViewRepresentable {
    class VideoPreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }
        
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
        
        // Focus view for tap-to-focus functionality
        let focusView: UIView = {
            let focusView = UIView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
            focusView.layer.borderColor = UIColor.white.cgColor
            focusView.layer.borderWidth = 1.5
            focusView.layer.cornerRadius = 25
            focusView.layer.opacity = 0
            focusView.backgroundColor = .clear
            return focusView
        }()
        
        @objc func focusAndExposeTap(gestureRecognizer: UITapGestureRecognizer) {
            let layerPoint = gestureRecognizer.location(in: gestureRecognizer.view)
            let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            
            let focusCircleDiam: CGFloat = 50
            let shiftedLayerPoint = CGPoint(x: layerPoint.x - (focusCircleDiam / 2),
                y: layerPoint.y - (focusCircleDiam / 2))
                        
            focusView.layer.frame = CGRect(origin: shiftedLayerPoint, size: CGSize(width: focusCircleDiam, height: focusCircleDiam))
            
            // Post notification for the ViewModel to handle focus
            NotificationCenter.default.post(.init(name: .init("UserDidRequestNewFocusPoint"), object: nil, userInfo: ["devicePoint": devicePoint] as [AnyHashable: Any]))
            
            // Animate the focus indicator
            UIView.animate(withDuration: 0.3, animations: {
                self.focusView.layer.opacity = 1
            }) { (completed) in
                if completed {
                    UIView.animate(withDuration: 0.3) {
                        self.focusView.layer.opacity = 0
                    }
                }
            }
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            
            self.layer.addSublayer(focusView.layer)
            
            let gRecognizer = UITapGestureRecognizer(target: self, action: #selector(VideoPreviewView.focusAndExposeTap(gestureRecognizer:)))
            self.addGestureRecognizer(gRecognizer)
        }
    }
    
    let session: AVCaptureSession
    let viewModel: CameraViewModel
    
    init(session: AVCaptureSession, viewModel: CameraViewModel) {
        self.session = session
        self.viewModel = viewModel
    }
    
    func makeUIView(context: Context) -> VideoPreviewView {
        let viewFinder = VideoPreviewView()
        viewFinder.backgroundColor = .black
        viewFinder.videoPreviewLayer.cornerRadius = 20
        viewFinder.videoPreviewLayer.masksToBounds = true
        viewFinder.videoPreviewLayer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        viewFinder.videoPreviewLayer.borderWidth = 1
        viewFinder.videoPreviewLayer.session = session
        viewFinder.videoPreviewLayer.videoGravity = .resizeAspectFill
        
        // Always keep the video preview in portrait orientation
        viewFinder.videoPreviewLayer.connection?.videoRotationAngle = 90
        
        print("DEBUG: FixedOrientationCameraPreview created with fixed portrait orientation")
        
        // Store a reference to the view in the ViewModel for later use
        viewModel.owningView = viewFinder
        
        return viewFinder
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        // Update the frame to match the parent view's bounds
        print("DEBUG: CameraPreview updateUIView called - ensuring proper bounds")
        uiView.videoPreviewLayer.frame = uiView.bounds
    }
} 