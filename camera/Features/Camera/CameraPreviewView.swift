import SwiftUI
import AVFoundation
import MetalKit
import CoreImage

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel
    
    func makeUIView(context: Context) -> PreviewView {
        // Use full screen for the preview
        let view = PreviewView(frame: UIScreen.main.bounds)
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.frame = UIScreen.main.bounds
        view.contentMode = .scaleAspectFill
        
        // Attach session to coordinator
        context.coordinator.session = session
        context.coordinator.previewView = view
        
        // Add video output
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(context.coordinator, queue: DispatchQueue(label: "videoQueue"))
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        return view
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Update orientation whenever SwiftUI triggers an update
        updatePreviewOrientation(uiView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    /// Compute rotation angle based on device interface orientation.
    private func updatePreviewOrientation(_ previewView: PreviewView) {
        var angle: CGFloat = 90 // Default for portrait
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            switch scene.interfaceOrientation {
            case .portrait:
                angle = 90
            case .landscapeRight:
                angle = 0
            case .landscapeLeft:
                angle = 180
            case .portraitUpsideDown:
                angle = 270
            default:
                angle = 90
            }
        }
        previewView.videoRotationAngle = angle
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
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                print("❌ Failed to get pixel buffer from sample buffer")
                return
            }
            
            // Create a base CIImage
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            print("📐 Buffer dimensions: \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
            
            // Apply LUT if present
            var finalImage = ciImage
            if let lutFilter = parent.lutManager.currentLUTFilter {
                lutFilter.setValue(ciImage, forKey: kCIInputImageKey)
                if let outputImage = lutFilter.outputImage {
                    finalImage = outputImage
                } else {
                    print("❌ LUT application failed - nil output")
                }
            }
            
            // Pass the final CIImage to the Metal view
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let preview = self.previewView else { return }
                // Indicate whether LOG is enabled
                preview.renderer?.isLogMode = self.parent.viewModel.isAppleLogEnabled
                preview.currentCIImage = finalImage
                preview.renderer?.currentCIImage = finalImage
                preview.metalView?.draw()
            }
        }
    }
    
    // MARK: - PreviewView
    class PreviewView: UIView {
        var metalView: MTKView?
        var renderer: MetalRenderer?
        
        // Rotation angle for the video (in degrees)
        var videoRotationAngle: CGFloat = 90 {
            didSet {
                renderer?.videoRotationAngle = videoRotationAngle
            }
        }
        
        var currentCIImage: CIImage? {
            didSet {
                // Request a redraw whenever the image changes
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
            
            // Create a MetalRenderer
            let renderer = MetalRenderer(metalDevice: device,
                                         pixelFormat: mtkView.colorPixelFormat)
            renderer?.videoRotationAngle = videoRotationAngle
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
        var videoRotationAngle: CGFloat = 90
        var isLogMode: Bool = false // For any optional LOG-based adjustments
        
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
            // Called whenever the view’s size changes
        }
        
        func draw(in view: MTKView) {
            guard let image = currentCIImage else {
                return
            }
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }
            
            let drawableSize = view.drawableSize
            let imageExtent = image.extent
            
            // 1. Convert rotation in degrees to radians
            let radians = videoRotationAngle * .pi / 180
            
            // 2. Create a rotation transform around (0,0)
            let rotation = CGAffineTransform(rotationAngle: radians)
            
            // 3. Apply rotation to find out the rotated bounding box
            let rotatedExtent = imageExtent.applying(rotation)
            
            // 4. Compute scale to fill the drawable (aspect fill)
            let scaleX = drawableSize.width / rotatedExtent.width
            let scaleY = drawableSize.height / rotatedExtent.height
            let scale = max(scaleX, scaleY)
            
            // 5. Build the final transform
            //    a) rotate around (0,0)
            //    b) scale up
            //    c) translate so that the image is centered in the drawable
            let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
            let scaledExtent = rotatedExtent.applying(scaleTransform)
            
            let offsetX = (drawableSize.width - scaledExtent.width) / 2 - scaledExtent.minX
            let offsetY = (drawableSize.height - scaledExtent.height) / 2 - scaledExtent.minY
            
            let translate = CGAffineTransform(translationX: offsetX, y: offsetY)
            
            let finalTransform = rotation.concatenating(scaleTransform).concatenating(translate)
            var finalImage = image.transformed(by: finalTransform)
            
            // Optional: mild color adjustments if isLogMode
            if isLogMode {
                finalImage = finalImage.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.1,
                    kCIInputBrightnessKey: 0.05
                ])
            }
            
            // 6. Render into the drawable
            ciContext.render(finalImage,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: CGRect(origin: .zero, size: drawableSize),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            
            // Track simple FPS
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
