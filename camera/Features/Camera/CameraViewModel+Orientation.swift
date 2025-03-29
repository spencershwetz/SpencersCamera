import AVFoundation
import UIKit

// MARK: - Orientation Extensions
extension CameraViewModel {
    
    func updateVideoOrientation() {
        guard let connection = videoDataOutput?.connection(with: .video),
              connection.isVideoRotationAngleSupported(90) else { return }
        
        // Only update video orientation if we're not recording
        if !isRecording {
            let deviceOrientation = UIDevice.current.orientation
            
            // Disable implicit animations to prevent glitches
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            
            switch deviceOrientation {
            case .portrait:
                connection.videoRotationAngle = 90
            case .portraitUpsideDown:
                connection.videoRotationAngle = 270
            case .landscapeLeft:
                connection.videoRotationAngle = 0
            case .landscapeRight:
                connection.videoRotationAngle = 180
            default:
                connection.videoRotationAngle = 90
            }
            
            CATransaction.commit()
        }
    }
    
    func updateInterfaceOrientation(lockCamera: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Disable animations during orientation changes
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                self.currentInterfaceOrientation = windowScene.interfaceOrientation
                
                // Only update connections if not recording or explicitly locking camera
                if !self.isRecording || lockCamera {
                    // Update video output connection
                    if let connection = self.videoDataOutput?.connection(with: .video) {
                        if connection.isVideoRotationAngleSupported(90) {
                            connection.videoRotationAngle = 90
                        }
                    }
                    
                    // Update all session connections
                    self.session.connections.forEach { connection in
                        if connection.isVideoRotationAngleSupported(90) {
                            connection.videoRotationAngle = 90
                        }
                    }
                    
                    // Update all session outputs and their connections
                    self.session.outputs.forEach { output in
                        output.connections.forEach { connection in
                            if connection.isVideoRotationAngleSupported(90) {
                                connection.videoRotationAngle = 90
                            }
                        }
                    }
                }
            }
            
            CATransaction.commit()
        }
    }
    
    func updateOrientation(_ orientation: UIInterfaceOrientation) {
        self.currentInterfaceOrientation = orientation
        updateInterfaceOrientation()
    }
    
    func enforceFixedOrientation() {
        guard isSessionRunning && !isOrientationLocked && !isRecording else { return }
        
        // If video library is presented, we should not enforce orientation
        guard !AppDelegate.isVideoLibraryPresented else {
            print("DEBUG: [ORIENTATION-DEBUG] Skipping camera orientation enforcement since video library is active")
            return
        }
        
        // If video library is not presented, enforce camera orientation
        DispatchQueue.main.async {
            self.videoDataOutput?.connections.forEach { connection in
                if connection.isVideoRotationAngleSupported(90) && connection.videoRotationAngle != 90 {
                    connection.videoRotationAngle = 90
                    print("DEBUG: Timer enforced fixed angle=90° on connection")
                }
            }
            
            self.session.connections.forEach { connection in
                if connection.isVideoRotationAngleSupported(90) && connection.videoRotationAngle != 90 {
                    connection.videoRotationAngle = 90
                }
            }
        }
    }
    
    func startOrientationMonitoring() {
        // Only start if not already locked
        guard !isOrientationLocked else { return }
        
        orientationMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, !self.isOrientationLocked else { return }
                
                // Skip enforcing orientation if video library is presented
                if !AppDelegate.isVideoLibraryPresented {
                    self.enforceFixedOrientation()
                } else {
                    print("DEBUG: [ORIENTATION-DEBUG] Skipping camera orientation enforcement since video library is active")
                }
            }
        }
        
        print("DEBUG: Started orientation monitoring timer")
    }
} 