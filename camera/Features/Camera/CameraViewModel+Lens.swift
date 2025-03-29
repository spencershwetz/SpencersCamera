import AVFoundation
import UIKit

// MARK: - Lens and Zoom Extensions
extension CameraViewModel {
    
    func switchToLens(_ lens: CameraLens) {
        print("DEBUG: 🔄 Switching to \(lens.rawValue)× lens")
        
        // For 2x zoom, we use digital zoom on the wide angle camera
        if lens == .x2 {
            guard let currentDevice = device,
                  currentDevice.deviceType == .builtInWideAngleCamera else {
                // Switch to wide angle first if we're not already on it
                switchToLens(.wide)
                return
            }
            
            do {
                try currentDevice.lockForConfiguration()
                currentDevice.ramp(toVideoZoomFactor: lens.zoomFactor, withRate: 20.0)
                currentDevice.unlockForConfiguration()
                currentLens = lens
                currentZoomFactor = lens.zoomFactor
                print("DEBUG: ✅ Set digital zoom to 2x")
            } catch {
                print("DEBUG: ❌ Failed to set digital zoom: \(error)")
                self.error = .configurationFailed
            }
            return
        }
        
        guard let newDevice = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
            print("DEBUG: ❌ Failed to get device for \(lens.rawValue)× lens")
            return
        }
        
        session.beginConfiguration()
        
        // Remove existing input
        if let currentInput = videoDeviceInput {
            session.removeInput(currentInput)
        }
        
        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                videoDeviceInput = newInput
                device = newDevice
                currentLens = lens
                currentZoomFactor = lens.zoomFactor
                
                // Reset zoom factor when switching physical lenses
                try newDevice.lockForConfiguration()
                newDevice.videoZoomFactor = 1.0
                let duration = CMTimeMake(value: 1000, timescale: Int32(selectedFrameRate * 1000))
                newDevice.activeVideoMinFrameDuration = duration
                newDevice.activeVideoMaxFrameDuration = duration
                newDevice.unlockForConfiguration()
                
                print("DEBUG: ✅ Successfully switched to \(lens.rawValue)× lens")
                
                // Update video orientation for the new connection
                if let connection = videoDataOutput?.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }
                    updateVideoOrientation()
                }
            } else {
                print("DEBUG: ❌ Cannot add input for \(lens.rawValue)× lens")
            }
        } catch {
            print("DEBUG: ❌ Error switching to \(lens.rawValue)× lens: \(error)")
            self.error = .configurationFailed
        }
        
        session.commitConfiguration()
    }
    
    func setZoomFactor(_ factor: CGFloat) {
        guard let currentDevice = device else { return }
        
        // Find the appropriate lens based on the zoom factor
        let targetLens = availableLenses
            .sorted { abs($0.zoomFactor - factor) < abs($1.zoomFactor - factor) }
            .first ?? .wide
        
        // If we need to switch lenses
        if targetLens != currentLens && abs(targetLens.zoomFactor - factor) < 0.5 {
            switchToLens(targetLens)
            return
        }
        
        do {
            try currentDevice.lockForConfiguration()
            
            // Calculate zoom factor relative to the current lens
            let baseZoom = currentLens.zoomFactor
            let relativeZoom = factor / baseZoom
            let zoomFactor = min(max(relativeZoom, currentDevice.minAvailableVideoZoomFactor),
                               currentDevice.maxAvailableVideoZoomFactor)
            
            // Apply zoom smoothly
            currentDevice.ramp(toVideoZoomFactor: zoomFactor,
                             withRate: 20.0)
            
            currentZoomFactor = factor
            lastZoomFactor = zoomFactor
            
            currentDevice.unlockForConfiguration()
        } catch {
            print("DEBUG: ❌ Failed to set zoom: \(error)")
            self.error = .configurationFailed
        }
    }
} 