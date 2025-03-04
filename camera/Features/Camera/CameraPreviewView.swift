import SwiftUI
import AVFoundation
import MetalKit

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
        updatePreviewOrientation(context.coordinator)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    private func updatePreviewOrientation(_ coordinator: Coordinator) {
        // Use the window scene's interface orientation for reliable detection
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            switch scene.interfaceOrientation {
            case .portrait:
                coordinator.videoRotationAngle = 90
            case .landscapeRight:
                coordinator.videoRotationAngle = 0
            case .landscapeLeft:
                coordinator.videoRotationAngle = 180
            case .portraitUpsideDown:
                coordinator.videoRotationAngle = 270
            default:
                coordinator.videoRotationAngle = 90
            }
        } else {
            coordinator.videoRotationAngle = 90
        }
    }
    
    class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let parent: CameraPreviewView
        let context = CIContext.shared
        var session: AVCaptureSession?
        // Rotation angle in degrees determined by interface orientation
        var videoRotationAngle: CGFloat = 90
        weak var previewView: PreviewView?
        
        // Metal-based rendering properties
        private var ciContext: CIContext?
        private var currentCIImage: CIImage?
        
        init(parent: CameraPreviewView) {
            self.parent = parent
            super.init()
            if let device = MTLCreateSystemDefaultDevice() {
                self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            }
        }
        
        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            print("📸 New frame received")
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                print("❌ Failed to get pixel buffer from sample buffer")
                return
            }
            
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            print("📐 Buffer dimensions: \(width)x\(height)")
            print("🎨 Pixel format: \(CVPixelBufferGetPixelFormatType(pixelBuffer))")
            
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            print("🌄 CIImage created - extent: \(ciImage.extent)")
            
            // Apply LUT if available
            if let lutFilter = parent.lutManager.currentLUTFilter {
                print("🔄 Attempting to apply LUT filter")
                lutFilter.setValue(ciImage, forKey: kCIInputImageKey)
                if let output = lutFilter.outputImage {
                    ciImage = output
                    print("✅ LUT applied successfully")
                    print("🖼️ Post-LUT image extent: \(ciImage.extent)")
                } else {
                    print("❌ LUT application failed - nil output")
                }
            }
            
            // Apply centered rotation transform based on computed angle
            let angleInRadians = videoRotationAngle * .pi / 180
            let center = CGPoint(x: ciImage.extent.midX, y: ciImage.extent.midY)
            let transform = CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(rotationAngle: angleInRadians))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            ciImage = ciImage.transformed(by: transform)
            print("🔄 Applied centered rotation transform: \(videoRotationAngle)°")
            
            currentCIImage = ciImage
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let previewView = self.previewView else { return }
                previewView.currentCIImage = self.currentCIImage
                previewView.setNeedsDisplay()
            }
        }
    }
    
    class PreviewView: UIView {
        // MetalKit view for rendering
        private var metalView: MTKView?
        private var renderer: MetalRenderer?
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
            
            let metalView = MTKView(frame: bounds, device: device)
            metalView.framebufferOnly = false
            metalView.colorPixelFormat = .bgra8Unorm
            metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            
            renderer = MetalRenderer(metalDevice: device, pixelFormat: metalView.colorPixelFormat)
            metalView.delegate = renderer
            
            addSubview(metalView)
            self.metalView = metalView
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            print("🖼️ Preview view layout: \(bounds.size)")
            metalView?.frame = bounds
        }
        
        override func setNeedsDisplay() {
            if let ciImage = currentCIImage {
                renderer?.currentCIImage = ciImage
                metalView?.draw()
            }
        }
    }
    
    class MetalRenderer: NSObject, MTKViewDelegate {
        private let commandQueue: MTLCommandQueue
        private let ciContext: CIContext
        var currentCIImage: CIImage?
        
        init?(metalDevice: MTLDevice, pixelFormat: MTLPixelFormat) {
            guard let commandQueue = metalDevice.makeCommandQueue() else {
                return nil
            }
            self.commandQueue = commandQueue
            self.ciContext = CIContext(mtlDevice: metalDevice, options: [.cacheIntermediates: false])
            super.init()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle view size changes if needed
        }
        
        func draw(in view: MTKView) {
            guard let currentDrawable = view.currentDrawable,
                  let ciImage = currentCIImage else {
                return
            }
            
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            
            // Scale and center the image to fill the view
            let imageExtent = ciImage.extent
            let drawableSize = view.drawableSize
            let scaleX = drawableSize.width / imageExtent.width
            let scaleY = drawableSize.height / imageExtent.height
            let scale = max(scaleX, scaleY)
            let scaledWidth = imageExtent.width * scale
            let scaledHeight = imageExtent.height * scale
            let tx = (drawableSize.width - scaledWidth) / 2.0
            let ty = (drawableSize.height - scaledHeight) / 2.0
            let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
            let translationTransform = CGAffineTransform(translationX: tx, y: ty)
            let transform = scaleTransform.concatenating(translationTransform)
            let transformedImage = ciImage.transformed(by: transform)
            
            ciContext.render(transformedImage,
                             to: currentDrawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: CGRect(origin: .zero, size: drawableSize),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            
            commandBuffer.present(currentDrawable)
            commandBuffer.commit()
        }
    }
}
