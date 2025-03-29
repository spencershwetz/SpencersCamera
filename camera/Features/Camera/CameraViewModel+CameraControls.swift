import AVFoundation
import CoreMedia

// MARK: - Camera Controls Extensions
extension CameraViewModel {
    
    func updateISO(_ iso: Float) {
        guard let device = device else { return }
        
        // Get the current device's supported ISO range
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        
        print("DEBUG: ISO update requested to \(iso). Device supports range: \(minISO) to \(maxISO)")
        
        // Ensure the ISO value is within the supported range
        let clampedISO = min(max(minISO, iso), maxISO)
        
        // Log if clamping occurred
        if clampedISO != iso {
            print("DEBUG: Clamped ISO from \(iso) to \(clampedISO) to stay within device limits")
        }
        
        do {
            try device.lockForConfiguration()
            
            // Double check that we're within range before setting
            device.setExposureModeCustom(duration: device.exposureDuration, iso: clampedISO) { _ in }
            device.unlockForConfiguration()
            
            // Update the published property with the actual value used
            DispatchQueue.main.async {
                self.iso = clampedISO
            }
            
            print("DEBUG: Successfully set ISO to \(clampedISO)")
        } catch {
            print("❌ ISO error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    func updateShutterSpeed(_ speed: CMTime) {
        guard let device = device else { return }
        do {
            try device.lockForConfiguration()
            
            // Get the current device's supported ISO range
            let minISO = device.activeFormat.minISO
            let maxISO = device.activeFormat.maxISO
            
            // Get current ISO value, either from device or our stored value
            let currentISO = device.iso
            
            // Ensure the ISO value is within the supported range
            let clampedISO = min(max(minISO, currentISO), maxISO)
            
            // If ISO is 0 or outside valid range, use our stored value or minISO as fallback
            let safeISO: Float
            if clampedISO <= 0 {
                safeISO = max(self.iso, minISO)
                print("DEBUG: Corrected invalid ISO \(currentISO) to \(safeISO)")
            } else {
                safeISO = clampedISO
            }
            
            device.setExposureModeCustom(duration: speed, iso: safeISO) { _ in }
            device.unlockForConfiguration()
            
            DispatchQueue.main.async {
                self.shutterSpeed = speed
                // Update our stored ISO if we had to correct it
                if safeISO != currentISO {
                    self.iso = safeISO
                }
            }
        } catch {
            print("❌ Shutter speed error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    var shutterAngle: Double {
        get {
            let angle = Double(shutterSpeed.value) / Double(shutterSpeed.timescale) * selectedFrameRate * 360.0
            let clampedAngle = min(max(angle, 1.1), 360.0)
            return clampedAngle
        }
        set {
            let clampedAngle = min(max(newValue, 1.1), 360.0)
            let duration = (clampedAngle/360.0) * (1.0/selectedFrameRate)
            let time = CMTimeMakeWithSeconds(duration, preferredTimescale: 1000000)
            updateShutterSpeed(time)
            DispatchQueue.main.async {
                self.shutterSpeed = time
            }
        }
    }
    
    func updateShutterAngle(_ angle: Double) {
        self.shutterAngle = angle
    }
    
    func updateExposureMode() {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            
            if isAutoExposureEnabled {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                    print("📷 Auto exposure enabled")
                }
            } else {
                if device.isExposureModeSupported(.custom) {
                    device.exposureMode = .custom
                    
                    // Double check ISO range limits
                    let minISO = device.activeFormat.minISO
                    let maxISO = device.activeFormat.maxISO
                    let clampedISO = min(max(minISO, self.iso), maxISO)
                    
                    if clampedISO != self.iso {
                        print("DEBUG: Exposure mode - Clamped ISO from \(self.iso) to \(clampedISO)")
                        DispatchQueue.main.async {
                            self.iso = clampedISO
                        }
                    }
                    
                    device.setExposureModeCustom(duration: device.exposureDuration,
                                                 iso: clampedISO) { _ in }
                    print("📷 Manual exposure enabled with ISO \(clampedISO)")
                }
            }
            
            device.unlockForConfiguration()
        } catch {
            print("❌ Error setting exposure mode: \(error.localizedDescription)")
            self.error = .configurationFailed
        }
    }
    
    func optimizeVideoCapture() {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            
            if device.activeFormat.isVideoStabilizationModeSupported(.cinematic) {
                if let connection = videoDataOutput?.connection(with: .video),
                   connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .cinematic
                }
            }
            
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            
            // Only set auto exposure if we're in auto mode
            if isAutoExposureEnabled {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            } else {
                // If in manual mode, ensure we have a valid ISO value
                if device.isExposureModeSupported(.custom) {
                    // Get the current device's supported ISO range
                    let minISO = device.activeFormat.minISO
                    let maxISO = device.activeFormat.maxISO
                    
                    // Ensure the ISO value is within the supported range
                    let clampedISO = min(max(minISO, self.iso), maxISO)
                    
                    // Update our stored value if needed
                    if clampedISO != self.iso {
                        print("DEBUG: Optimizing video - Clamped ISO from \(self.iso) to \(clampedISO)")
                        DispatchQueue.main.async {
                            self.iso = clampedISO
                        }
                    }
                    
                    device.exposureMode = .custom
                    device.setExposureModeCustom(duration: device.exposureDuration, 
                                                iso: clampedISO) { _ in }
                }
            }
            
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            device.unlockForConfiguration()
        } catch {
            print("Error optimizing video capture: \(error)")
        }
    }
    
    func findCompatibleFormat(for fps: Double) -> AVCaptureDevice.Format? {
        guard let device = device else { return nil }
        
        let targetFps = fps
        let tolerance = 0.01
        
        let formats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let isHighRes = dimensions.width >= 1920
            let supportsFrameRate = format.videoSupportedFrameRateRanges.contains { range in
                if abs(targetFps - 23.976) < 0.001 {
                    return range.minFrameRate <= (targetFps - tolerance) &&
                           (targetFps + tolerance) <= range.maxFrameRate
                } else {
                    return range.minFrameRate <= targetFps && targetFps <= range.maxFrameRate
                }
            }
            
            if isAppleLogEnabled {
                return isHighRes && supportsFrameRate && format.supportedColorSpaces.contains(.appleLog)
            }
            return isHighRes && supportsFrameRate
        }
        
        return formats.first
    }
    
    func updateFrameRate(_ fps: Double) {
        guard let device = device else { return }
        
        do {
            guard let compatibleFormat = findCompatibleFormat(for: fps) else {
                print("❌ No compatible format found for \(fps) fps")
                DispatchQueue.main.async {
                    self.error = .configurationFailed(message: "This device doesn't support \(fps) fps recording")
                }
                return
            }
            
            try device.lockForConfiguration()
            
            if device.activeFormat != compatibleFormat {
                print("Switching to compatible format...")
                device.activeFormat = compatibleFormat
            }
            
            let frameDuration: CMTime
            switch fps {
            case 23.976:
                frameDuration = FrameRates.ntsc23_976
                print("Setting 23.976 fps with duration \(FrameRates.ntsc23_976.value)/\(FrameRates.ntsc23_976.timescale)")
            case 29.97:
                frameDuration = FrameRates.ntsc29_97
            case 24:
                frameDuration = FrameRates.film24
            case 25:
                frameDuration = FrameRates.pal25
            case 30:
                frameDuration = FrameRates.ntsc30
            default:
                frameDuration = CMTimeMake(value: 1, timescale: Int32(fps))
            }
            
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.selectedFrameRate = fps
                self.frameCount = 0
                self.frameRateAccumulator = 0
                self.lastFrameTime = nil
            }
            
            device.unlockForConfiguration()
            
            let currentAngle = shutterAngle
            updateShutterAngle(currentAngle)
        } catch {
            print("❌ Frame rate error: \(error)")
            self.error = .configurationFailed(message: "Failed to set \(fps) fps: \(error.localizedDescription)")
        }
    }
    
    func adjustFrameRatePrecision(currentFPS: Double) {
        let deviation = abs(currentFPS - selectedFrameRate) / selectedFrameRate
        guard deviation > 0.02 else { return }
        
        let now = Date().timeIntervalSince1970
        guard (now - lastAdjustmentTime) > 1.0 else { return }
        
        lastAdjustmentTime = now
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateFrameRate(self.selectedFrameRate)
        }
    }
    
    func updateCameraFormat(for resolution: Resolution) async throws {
        guard let device = device else { return }
        
        print("\n=== Updating Camera Format ===")
        print("🎯 Target Resolution: \(resolution.rawValue)")
        print("🎥 Current Frame Rate: \(selectedFrameRate)")
        
        let wasRunning = session.isRunning
        if wasRunning {
            session.stopRunning()
        }
        
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            // Find all formats that match our resolution
            let matchingFormats = device.formats.filter { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dimensions.width == resolution.dimensions.width &&
                       dimensions.height == resolution.dimensions.height
            }
            
            print("📊 Found \(matchingFormats.count) matching formats")
            
            // Find the best format that supports our current frame rate
            let bestFormat = matchingFormats.first { format in
                format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate...range.maxFrameRate ~= selectedFrameRate
                }
            } ?? matchingFormats.first
            
            guard let selectedFormat = bestFormat else {
                print("❌ No compatible format found for resolution \(resolution.rawValue)")
                if wasRunning {
                    session.startRunning()
                }
                throw CameraError.configurationFailed
            }
            
            // Begin configuration
            session.beginConfiguration()
            
            // Set the format
            device.activeFormat = selectedFormat
            
            // Set the frame duration
            let duration = CMTime(value: 1, timescale: CMTimeScale(selectedFrameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            
            // Update video configuration
            updateVideoConfiguration()
            
            // Commit the configuration
            session.commitConfiguration()
            
            // Restore session state if it was running
            if wasRunning {
                session.startRunning()
            }
            
            print("✅ Camera format updated successfully")
            print("=== End Update ===\n")
            
        } catch {
            print("❌ Error updating camera format: \(error.localizedDescription)")
            session.commitConfiguration()
            
            if wasRunning {
                session.startRunning()
            }
            
            throw error
        }
    }
} 