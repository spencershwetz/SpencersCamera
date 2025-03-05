//
//  CameraPreviewView.swift
//  YourApp
//
//  iOS 18+ only, using AVCaptureConnection.videoRotationAngle
//

import SwiftUI
import AVFoundation
import MetalKit
import CoreImage

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel
    
    func makeUIView(context: Context) -> PreviewView {
        // Fullscreen preview
        let preview = PreviewView(frame: UIScreen.main.bounds)
        preview.backgroundColor = .black
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        preview.contentMode = .scaleAspectFill
        
        // Connect session to coordinator
        context.coordinator.session = session
        context.coordinator.previewView = preview
        
        // Configure video output
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // Process frames on a background queue
        videoOutput.setSampleBufferDelegate(context.coordinator,
                                            queue: DispatchQueue(label: "videoQueue"))
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        return preview
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Called when SwiftUI invalidates the view.
        // We do not do orientation logic here—it's handled in the Coordinator.
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    // MARK: - Coordinator
    class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let parent: CameraPreviewView
        var session: AVCaptureSession?
        weak var previewView: PreviewView?
        
        init(parent: CameraPreviewView) {
            self.parent = parent
            super.init()
        }
        
        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            // Determine device orientation
            let deviceOrientation = UIDevice.current.orientation
            
            // Map to a rotation angle. If .unknown or .faceUp, fallback to 90 (portrait).
            let angle = deviceOrientation.videoRotationAngle
            
            // Debug logging
            print("🔄 Detected deviceOrientation: \(deviceOrientation.rawValue), mapping to angle=\(angle)")
            
            // Directly set the rotation angle on the connection (iOS 17+)
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                print("✅ Applied videoRotationAngle = \(angle)")
            } else {
                print("⚠️ videoRotationAngle=\(angle) is NOT supported by this connection.")
            }
            
            // Grab the pixel buffer
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                print("❌ Could not get pixel buffer from sample buffer.")
                return
            }
            
            // Create a CIImage from the camera frame
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            print("📐 Buffer size: \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
            
            // Optionally apply LUT
            var finalImage = ciImage
            if let lutFilter = parent.lutManager.currentLUTFilter {
                lutFilter.setValue(ciImage, forKey: kCIInputImageKey)
                if let outputImage = lutFilter.outputImage {
                    finalImage = outputImage
                } else {
                    print("❌ LUT application failed (nil output).")
                }
            }
            
            // Dispatch to main thread to update the preview
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let preview = self.previewView else { return }
                
                // Let the renderer know if we’re in Apple Log mode
                preview.renderer?.isLogMode = self.parent.viewModel.isAppleLogEnabled
                
                // Update the final CIImage
                preview.currentCIImage = finalImage
                preview.renderer?.currentCIImage = finalImage
                
                // Force a draw immediately
                preview.metalView?.draw()
            }
        }
    }
    
    // MARK: - PreviewView
    class PreviewView: UIView {
        var metalView: MTKView?
        var renderer: MetalRenderer?
        
        // The current image to render
        var currentCIImage: CIImage? {
            didSet {
                // Mark for redraw
                metalView?.setNeedsDisplay()
            }
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setupMetalView()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupMetalView()
        }
        
        private func setupMetalView() {
            guard let device = MTLCreateSystemDefaultDevice() else {
                print("❌ Metal is not supported on this device.")
                return
            }
            
            let mtkView = MTKView(frame: bounds, device: device)
            mtkView.framebufferOnly = false
            mtkView.colorPixelFormat = .bgra8Unorm
            mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            mtkView.backgroundColor = .black
            mtkView.contentMode = .scaleAspectFill
            
            let metalRenderer = MetalRenderer(metalDevice: device,
                                              pixelFormat: mtkView.colorPixelFormat)
            mtkView.delegate = metalRenderer
            
            addSubview(mtkView)
            metalView = mtkView
            renderer = metalRenderer
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            metalView?.frame = bounds
        }
    }
    
    // MARK: - MetalRenderer
    class MetalRenderer: NSObject, MTKViewDelegate {
        private let commandQueue: MTLCommandQueue
        private let ciContext: CIContext
        
        var currentCIImage: CIImage?
        var isLogMode: Bool = false
        
        // Simple FPS tracking
        private var lastTime: CFTimeInterval = CACurrentMediaTime()
        private var frameCount: Int = 0
        
        init?(metalDevice: MTLDevice, pixelFormat: MTLPixelFormat) {
            guard let queue = metalDevice.makeCommandQueue() else {
                return nil
            }
            commandQueue = queue
            ciContext = CIContext(mtlDevice: metalDevice,
                                  options: [.cacheIntermediates: false])
            super.init()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Called when the view size changes
        }
        
        func draw(in view: MTKView) {
            guard let image = currentCIImage else { return }
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            
            let drawableSize = view.drawableSize
            let imageSize = image.extent.size
            
            // Aspect-fill scale to fill the entire screen
            let scaleX = drawableSize.width / imageSize.width
            let scaleY = drawableSize.height / imageSize.height
            let scale = max(scaleX, scaleY)
            
            // Center the scaled image in the drawable
            let scaledWidth = imageSize.width * scale
            let scaledHeight = imageSize.height * scale
            let offsetX = (drawableSize.width - scaledWidth) * 0.5
            let offsetY = (drawableSize.height - scaledHeight) * 0.5
            
            // Build transform
            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: offsetX, y: offsetY)
            transform = transform.scaledBy(x: scale, y: scale)
            
            // If Apple Log is enabled, apply mild color adjustments
            var finalImage = image.transformed(by: transform)
            if isLogMode {
                finalImage = finalImage.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.1,
                    kCIInputBrightnessKey: 0.05
                ])
            }
            
            // Render into the drawable
            ciContext.render(
                finalImage,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: CGRect(origin: .zero, size: drawableSize),
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            
            // Basic FPS log
            frameCount += 1
            let now = CACurrentMediaTime()
            let elapsed = now - lastTime
            if elapsed >= 1.0 {
                let fps = Double(frameCount) / elapsed
                print("🎞 FPS: \(Int(fps))")
                frameCount = 0
                lastTime = now
            }
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// MARK: - UIDeviceOrientation -> Rotation Angle (iOS 17+)
// For iOS 18+ only, but same method:
fileprivate extension UIDeviceOrientation {
    /// Convert the device orientation to the correct rotation angle (in degrees)
    /// for the camera feed. Tweak these if you find any orientation is flipped.
    var videoRotationAngle: CGFloat {
        switch self {
        case .portrait:
            // Typically 90 for portrait
            return 90
        case .portraitUpsideDown:
            // 270 for upside-down portrait
            return 90
        case .landscapeLeft:
            // 0 for phone turned right
            return 0
        case .landscapeRight:
            // 180 for phone turned left
            return 180
        default:
            // Fallback to portrait
            return 90
        }
    }
}
