import SwiftUI
import AVFoundation
import MetalKit
import CoreImage

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var lutManager: LUTManager
    let viewModel: CameraViewModel

    func makeUIView(context: Context) -> PreviewView {
        let preview = PreviewView(frame: UIScreen.main.bounds)
        preview.backgroundColor = .black
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        preview.contentMode = .scaleAspectFill
        
        context.coordinator.session = session
        context.coordinator.previewView = preview
        
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [ kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA ]
        videoOutput.setSampleBufferDelegate(context.coordinator, queue: DispatchQueue(label: "videoQueue"))
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        return preview
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) { }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let parent: CameraPreviewView
        var session: AVCaptureSession?
        weak var previewView: PreviewView?
        private var lastInterfaceOrientation: UIInterfaceOrientation?
        
        init(parent: CameraPreviewView) {
            self.parent = parent
            super.init()
        }
        
        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            // Get current interface orientation on the main thread safely.
            let currentOrientation: UIInterfaceOrientation = DispatchQueue.main.sync {
                return UIApplication.shared.windows.first?.windowScene?.interfaceOrientation ?? .portrait
            }
            
            // Desired mapping:
            // Portrait          -> 90°
            // Portrait UpsideDown -> 270°
            // Landscape Left    -> 180°
            // Landscape Right   -> 0°
            let newAngle: CGFloat
            switch currentOrientation {
            case .portrait:
                newAngle = 90
            case .portraitUpsideDown:
                newAngle = 270
            case .landscapeLeft:
                newAngle = 180
            case .landscapeRight:
                newAngle = 0
            default:
                newAngle = 90
            }
            
            if lastInterfaceOrientation != currentOrientation {
                print("🔄 Interface orientation changed: \(currentOrientation.rawValue) mapped to angle=\(newAngle)")
                lastInterfaceOrientation = currentOrientation
            }
            
            if connection.isVideoRotationAngleSupported(newAngle) {
                connection.videoRotationAngle = newAngle
            } else {
                print("⚠️ videoRotationAngle \(newAngle) not supported by connection")
            }
            
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                print("❌ Failed to get pixel buffer")
                return
            }
            
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            var finalImage = ciImage
            if let lutFilter = parent.lutManager.currentLUTFilter {
                lutFilter.setValue(ciImage, forKey: kCIInputImageKey)
                if let outputImage = lutFilter.outputImage {
                    finalImage = outputImage
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let preview = self.previewView else { return }
                preview.renderer?.isLogMode = self.parent.viewModel.isAppleLogEnabled
                preview.currentCIImage = finalImage
                preview.renderer?.currentCIImage = finalImage
                preview.metalView?.draw()
            }
        }
    }
    
    class PreviewView: UIView {
        var metalView: MTKView?
        var renderer: MetalRenderer?
        
        var currentCIImage: CIImage? {
            didSet {
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
            
            let metalRenderer = MetalRenderer(metalDevice: device, pixelFormat: mtkView.colorPixelFormat)
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
    
    class MetalRenderer: NSObject, MTKViewDelegate {
        private let commandQueue: MTLCommandQueue
        private let ciContext: CIContext
        
        var currentCIImage: CIImage?
        var isLogMode: Bool = false
        
        private var lastTime: CFTimeInterval = CACurrentMediaTime()
        private var frameCount: Int = 0
        
        init?(metalDevice: MTLDevice, pixelFormat: MTLPixelFormat) {
            guard let queue = metalDevice.makeCommandQueue() else { return nil }
            commandQueue = queue
            ciContext = CIContext(mtlDevice: metalDevice, options: [.cacheIntermediates: false])
            super.init()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
        
        func draw(in view: MTKView) {
            guard let image = currentCIImage,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            
            let drawableSize = view.drawableSize
            let imageSize = image.extent.size
            let scaleX = drawableSize.width / imageSize.width
            let scaleY = drawableSize.height / imageSize.height
            let scale = max(scaleX, scaleY)
            let scaledWidth = imageSize.width * scale
            let scaledHeight = imageSize.height * scale
            let offsetX = (drawableSize.width - scaledWidth) * 0.5
            let offsetY = (drawableSize.height - scaledHeight) * 0.5
            
            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: offsetX, y: offsetY)
            transform = transform.scaledBy(x: scale, y: scale)
            
            var finalImage = image.transformed(by: transform)
            if isLogMode {
                finalImage = finalImage.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.1,
                    kCIInputBrightnessKey: 0.05
                ])
            }
            
            ciContext.render(finalImage,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: CGRect(origin: .zero, size: drawableSize),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            
            frameCount += 1
            let now = CACurrentMediaTime()
            if now - lastTime >= 1.0 {
                print("🎞 FPS: \(frameCount)")
                frameCount = 0
                lastTime = now
            }
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
