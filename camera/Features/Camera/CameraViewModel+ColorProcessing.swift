import AVFoundation
import CoreMedia
import os.log

// MARK: - Color Processing Extensions
extension CameraViewModel {
    
    func configureAppleLog() async throws {
        print("\n=== Configuring Apple Log ===")
        
        guard let device = device else {
            print("❌ No camera device available")
            throw CameraError.configurationFailed
        }
        
        do {
            session.stopRunning()
            print("⏸️ Session stopped for reconfiguration")
            
            try await Task.sleep(for: .milliseconds(100))
            session.beginConfiguration()
            
            do {
                try device.lockForConfiguration()
            } catch {
                throw CameraError.configurationFailed
            }
            
            defer {
                device.unlockForConfiguration()
                session.commitConfiguration()
                
                if let videoConnection = videoDataOutput?.connection(with: .video) {
                    updateVideoOrientation()
                }
                
                session.startRunning()
            }
            
            // Check available codecs first
            let availableCodecs = videoDataOutput?.availableVideoCodecTypes ?? []
            print("📝 Available codecs: \(availableCodecs)")
            
            // Find a format that supports Apple Log
            let formats = device.formats.filter { format in
                let desc = format.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
                let matchesResolution = dimensions.width >= selectedResolution.dimensions.width &&
                                      dimensions.height >= selectedResolution.dimensions.height
                return hasAppleLog && matchesResolution
            }
            
            guard let selectedFormat = formats.first else {
                print("❌ No suitable Apple Log format found")
                throw CameraError.configurationFailed
            }
            
            print("✅ Found suitable Apple Log format")
            
            // Set the format first
            device.activeFormat = selectedFormat
            
            // Verify the format supports Apple Log
            guard selectedFormat.supportedColorSpaces.contains(.appleLog) else {
                print("❌ Selected format does not support Apple Log")
                throw CameraError.configurationFailed
            }
            
            print("✅ Format supports Apple Log")
            
            // Set frame duration
            let duration = CMTimeMake(value: 1000, timescale: Int32(selectedFrameRate * 1000))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            
            // Configure HDR if supported
            if selectedFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = true
                print("✅ Enabled HDR support")
            }
            
            // Set color space
            device.activeColorSpace = .appleLog
            print("✅ Set color space to Apple Log")
            
            // Update video configuration
            updateVideoConfiguration()
            print("🎬 Updated video configuration for codec: \(selectedCodec.rawValue)")
            
            print("✅ Successfully configured Apple Log format")
            
        } catch {
            print("❌ Error configuring Apple Log: \(error)")
            throw error
        }
        
        print("=== End Apple Log Configuration ===\n")
    }
    
    func resetAppleLog() async throws {
        print("\n=== Resetting Apple Log ===")
        
        guard let device = device else {
            print("❌ No camera device available")
            throw CameraError.configurationFailed
        }
        
        do {
            session.stopRunning()
            print("⏸️ Session stopped for reconfiguration")
            
            try await Task.sleep(for: .milliseconds(100))
            session.beginConfiguration()
            
            do {
                try device.lockForConfiguration()
            } catch {
                throw CameraError.configurationFailed
            }
            
            defer {
                device.unlockForConfiguration()
                session.commitConfiguration()
                
                if let videoConnection = videoDataOutput?.connection(with: .video) {
                    updateVideoOrientation()
                }
                
                session.startRunning()
            }
            
            // Find a format that matches our resolution
            let formats = device.formats.filter { format in
                let desc = format.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                return dimensions.width >= selectedResolution.dimensions.width &&
                       dimensions.height >= selectedResolution.dimensions.height
            }
            
            guard let selectedFormat = formats.first else {
                print("❌ No suitable format found")
                throw CameraError.configurationFailed
            }
            
            print("✅ Found suitable format")
            
            // Set the format
            device.activeFormat = selectedFormat
            
            // Set frame duration
            let duration = CMTimeMake(value: 1000, timescale: Int32(selectedFrameRate * 1000))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            
            // Reset HDR settings
            if selectedFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = true
                print("✅ Reset HDR settings")
            }
            
            // Reset color space
            device.activeColorSpace = .sRGB
            print("✅ Reset color space to sRGB")
            
            // Update video configuration
            updateVideoConfiguration()
            print("🎬 Updated video configuration for codec: \(selectedCodec.rawValue)")
            
            print("✅ Successfully reset Apple Log format")
            
        } catch {
            print("❌ Error resetting Apple Log: \(error)")
            throw error
        }
        
        print("=== End Apple Log Reset ===\n")
    }
    
    func findBestAppleLogFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        return device.formats.first { format in
            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            let codecType = CMFormatDescriptionGetMediaSubType(desc)
            
            let is4K = (dimensions.width == 3840 && dimensions.height == 2160)
            let isProRes422 = (codecType == kCMVideoCodecType_AppleProRes422)
            let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
            
            return is4K && isProRes422 && hasAppleLog
        }
    }
    
    func updateTint(_ newValue: Double) {
        currentTint = newValue.clamped(to: tintRange)
        configureTintSettings()
    }
    
    private func configureTintSettings() {
        guard let device = device else { return }
        
        do {
            try device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
                
                let currentGains = device.deviceWhiteBalanceGains
                var newGains = currentGains
                let tintScale = currentTint / 150.0
                
                if tintScale > 0 {
                    newGains.greenGain = currentGains.greenGain * (1.0 + Float(tintScale))
                } else {
                    let magentaScale = 1.0 + Float(abs(tintScale))
                    newGains.redGain = currentGains.redGain * magentaScale
                    newGains.blueGain = currentGains.blueGain * magentaScale
                }
                
                let maxGain = device.maxWhiteBalanceGain
                newGains.redGain = min(max(1.0, newGains.redGain), maxGain)
                newGains.greenGain = min(max(1.0, newGains.greenGain), maxGain)
                newGains.blueGain = min(max(1.0, newGains.blueGain), maxGain)
                
                device.setWhiteBalanceModeLocked(with: newGains) { _ in }
            }
            device.unlockForConfiguration()
        } catch {
            print("Error setting tint: \(error.localizedDescription)")
            self.error = .whiteBalanceError
        }
    }
    
    func updateWhiteBalance(_ temperature: Float) {
        guard let device = device else { return }
        do {
            try device.lockForConfiguration()
            let tnt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0.0)
            var gains = device.deviceWhiteBalanceGains(for: tnt)
            let maxGain = device.maxWhiteBalanceGain
            
            gains.redGain   = min(max(1.0, gains.redGain), maxGain)
            gains.greenGain = min(max(1.0, gains.greenGain), maxGain)
            gains.blueGain  = min(max(1.0, gains.blueGain), maxGain)
            
            device.setWhiteBalanceModeLocked(with: gains) { _ in }
            device.unlockForConfiguration()
            
            whiteBalance = temperature
        } catch {
            print("White balance error: \(error)")
            self.error = .configurationFailed
        }
    }
    
    private func configureHDR() {
        guard let device = device,
              device.activeFormat.isVideoHDRSupported else { return }
        
        do {
            try device.lockForConfiguration()
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = true
            device.unlockForConfiguration()
        } catch {
            print("Error configuring HDR: \(error)")
        }
    }
} 