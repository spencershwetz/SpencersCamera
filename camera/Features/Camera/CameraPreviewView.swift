import SwiftUI
import AVFoundation
import MetalKit
import CoreImage

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel
    
    func makeUIView(context: Context) -> PreviewView {
        // Full-screen view for camera
        let preview = PreviewView(frame: UIScreen.main.bounds)
        preview.backgroundColor = .black
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        preview.contentMode = .scaleAspectFill
        
        // Attach session to coordinator
        context.coordinator.session = session
        context.coordinator.previewView = preview
        
        // Set up the video output
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // Process frames on a background queue
        videoOutput.setSampleBufferDelegate(context.coordinator, queue: DispatchQueue(label: "videoQueue"))
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        return preview
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        // SwiftUI might call this on orientation changes or other state updates
        // We don’t do extra rotation logic here; we rely on the capture connection
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
            // -- 1) Force or adapt orientation if needed --
            // If you see a sideways feed, try changing this to .portrait or another fixed orientation.
            // E.g.:
            // connection.videoOrientation = .portrait
            // or do logic to match device orientation, etc.
            if let deviceOrientation = UIDevice.current.orientation.videoOrientation {
                connection.videoOrientation = deviceOrientation
            } else {
                // fallback if device orientation is .unknown
                connection.videoOrientation = .portrait
            }
            
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                print("❌ Could not get pixel buffer from sample buffer")
                return
            }
            
            // Create a CIImage from the camera frame
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            print("📐 Buffer size: \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
            
            // Optionally apply a LUT
            var finalImage = ciImage
            if let lutFilter = parent.lutManager.currentLUTFilter {
                lutFilter.setValue(ciImage, forKey: kCIInputImageKey)
                if let outputImage = lutFilter.outputImage {
                    finalImage = outputImage
                } else {
                    print("❌ LUT application failed (nil output)")
                }
            }
            
            // Hand off the final CIImage to the main thread for rendering
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let preview = self.previewView else { return }
                
                // Let the renderer know if we’re in Apple Log mode
                preview.renderer?.isLogMode = self.parent.viewModel.isAppleLogEnabled
                
                // Update the image to display
                preview.currentCIImage = finalImage
                preview.renderer?.currentCIImage = finalImage
                // Force a draw
                preview.metalView?.draw()
            }
        }
    }
    
    // MARK: - PreviewView
    class PreviewView: UIView {
        var metalView: MTKView?
        var renderer: MetalRenderer?
        
        // The CIImage we want to render
        var currentCIImage: CIImage? {
            didSet {
                // Mark for redraw whenever a new frame arrives
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
                print("❌ Metal is not supported on this device")
                return
            }
            
            let mtkView = MTKView(frame: bounds, device: device)
            mtkView.framebufferOnly = false
            mtkView.colorPixelFormat = .bgra8Unorm
            mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            mtkView.backgroundColor = .black
            mtkView.contentMode = .scaleAspectFill
            
            let renderer = MetalRenderer(metalDevice: device, pixelFormat: mtkView.colorPixelFormat)
            mtkView.delegate = renderer
            
            addSubview(mtkView)
            metalView = mtkView
            self.renderer = renderer
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
            self.commandQueue = queue
            self.ciContext = CIContext(mtlDevice: metalDevice,
                                       options: [.cacheIntermediates: false])
            super.init()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Called when the view’s size changes
        }
        
        func draw(in view: MTKView) {
            guard let image = currentCIImage else { return }
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            
            let drawableSize = view.drawableSize
            let imageSize = image.extent.size
            
            // Aspect-fill scaling to fill the screen
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
            
            // If you need to tweak for LOG mode, do it here
            var finalImage = image.transformed(by: transform)
            if isLogMode {
                finalImage = finalImage.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.1,
                    kCIInputBrightnessKey: 0.05
                ])
            }
            
            // Render to screen
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

// MARK: - UIDeviceOrientation -> AVCaptureVideoOrientation
fileprivate extension UIDeviceOrientation {
    var videoOrientation: AVCaptureVideoOrientation? {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight  // iPhone device rotated left => camera rotates right
        case .landscapeRight: return .landscapeLeft  // iPhone device rotated right => camera rotates left
        default: return nil
        }
    }
}
