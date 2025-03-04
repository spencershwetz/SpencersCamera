import SwiftUI
import AVFoundation
import MetalKit
import CoreImage

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        // Connect the session to the coordinator
        context.coordinator.session = session
        context.coordinator.previewView = view
        
        // Configure video output
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
        // Update orientation if needed
        updatePreviewOrientation(uiView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    /// Compute the rotation angle based on the window scene orientation
    private func updatePreviewOrientation(_ previewView: PreviewView) {
        var angle: CGFloat = 90 // default portrait rotation
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
    
    class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let parent: CameraPreviewView
        let context = CIContext.shared
        var session: AVCaptureSession?
        weak var previewView: PreviewView?
        // Remove rotation transform here so that we pass the raw CIImage to the view
        
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
            
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            print("📐 Buffer dimensions: \(width)x\(height)")
            print("🎨 Pixel format: \(CVPixelBufferGetPixelFormatType(pixelBuffer))")
            
            // Create CIImage without any rotation transform
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            print("🌄 CIImage created - extent: \(ciImage.extent)")
            
            // Apply LUT if available
            var finalImage = ciImage
            if let lutFilter = parent.lutManager.currentLUTFilter {
                lutFilter.setValue(finalImage, forKey: kCIInputImageKey)
                if let outputImage = lutFilter.outputImage {
                    finalImage = outputImage
                    print("✅ LUT applied successfully")
                } else {
                    print("❌ LUT application failed - nil output")
                }
            }
            
            // Store the unrotated image; rotation/scaling will be applied in the Metal renderer.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let previewView = self.previewView else { return }
                previewView.currentCIImage = finalImage
                previewView.setNeedsDisplay()
            }
        }
    }
    
    class PreviewView: UIView {
        // MetalKit view for rendering
        private var metalView: MTKView?
        var renderer: MetalRenderer?
        
        // New property to control rotation (in degrees)
        var videoRotationAngle: CGFloat = 90 {
            didSet {
                renderer?.videoRotationAngle = videoRotationAngle
            }
        }
        
        var currentCIImage: CIImage?
        
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
            
            renderer = MetalRenderer(metalDevice: device, pixelFormat: mtkView.colorPixelFormat)
            // Initialize with the default rotation
            renderer?.videoRotationAngle = videoRotationAngle
            mtkView.delegate = renderer
            
            addSubview(mtkView)
            self.metalView = mtkView
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            metalView?.frame = bounds
        }
        
        override func setNeedsDisplay() {
            if let _ = currentCIImage {
                renderer?.currentCIImage = currentCIImage
                metalView?.draw()
            }
        }
    }
    
    class MetalRenderer: NSObject, MTKViewDelegate {
        private let commandQueue: MTLCommandQueue
        private let ciContext: CIContext
        var currentCIImage: CIImage?
        // New property to store the rotation angle (in degrees)
        var videoRotationAngle: CGFloat = 90
        
        init?(metalDevice: MTLDevice, pixelFormat: MTLPixelFormat) {
            guard let queue = metalDevice.makeCommandQueue() else {
                return nil
            }
            self.commandQueue = queue
            self.ciContext = CIContext(mtlDevice: metalDevice, options: [.cacheIntermediates: false])
            super.init()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle view size changes if needed
        }
        
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let image = currentCIImage,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }
            
            // 1. Apply rotation using the videoRotationAngle property.
            let radians = videoRotationAngle * CGFloat.pi / 180
            let rotatedImage = image.transformed(by: CGAffineTransform(rotationAngle: radians))
            
            // 2. Scale the rotated image to fill the drawable.
            let imageExtent = rotatedImage.extent
            let drawableSize = view.drawableSize
            let scaleX = drawableSize.width / imageExtent.width
            let scaleY = drawableSize.height / imageExtent.height
            let scale = max(scaleX, scaleY)
            let scaledImage = rotatedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            
            // 3. Center the image.
            let centeredX = (drawableSize.width - scaledImage.extent.width) / 2.0
            let centeredY = (drawableSize.height - scaledImage.extent.height) / 2.0
            let centeredImage = scaledImage.transformed(by: CGAffineTransform(translationX: centeredX, y: centeredY))
            
            // Render the final image.
            ciContext.render(centeredImage,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: CGRect(origin: .zero, size: drawableSize),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
