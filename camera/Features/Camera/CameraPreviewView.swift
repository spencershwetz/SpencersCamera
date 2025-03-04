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
        let currentDevice = UIDevice.current
        let orientation = currentDevice.orientation
        
        if #available(iOS 17.0, *) {
            switch orientation {
            case .portrait:
                coordinator.videoRotationAngle = 90
            case .landscapeRight: // Device rotated left
                coordinator.videoRotationAngle = 180
            case .landscapeLeft: // Device rotated right
                coordinator.videoRotationAngle = 0
            case .portraitUpsideDown:
                coordinator.videoRotationAngle = 270
            default:
                coordinator.videoRotationAngle = 90
            }
        } else {
            switch orientation {
            case .portrait:
                coordinator.videoOrientation = .portrait
            case .landscapeRight: // Device rotated left
                coordinator.videoOrientation = .landscapeLeft
            case .landscapeLeft: // Device rotated right
                coordinator.videoOrientation = .landscapeRight
            case .portraitUpsideDown:
                coordinator.videoOrientation = .portraitUpsideDown
            default:
                coordinator.videoOrientation = .portrait
            }
        }
    }
    
    class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let parent: CameraPreviewView
        let context = CIContext.shared
        var session: AVCaptureSession?
        var videoOrientation: AVCaptureVideoOrientation = .portrait
        var videoRotationAngle: CGFloat = 90
        weak var previewView: PreviewView?
        
        // Metal-based rendering properties
        private var ciContext: CIContext?
        private var currentCIImage: CIImage?
        
        init(parent: CameraPreviewView) {
            self.parent = parent
            super.init()
            
            // Create Metal-based CIContext for efficient rendering
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
            
            // Log buffer details
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
            
            // Store the current image to be rendered by the MetalView
            currentCIImage = ciImage
            
            // Update the Metal view on main thread
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
            metalView.framebufferOnly = false // Allow compute processing
            metalView.colorPixelFormat = .bgra8Unorm
            metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            
            // Create renderer
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
    
    // Metal renderer to efficiently render CIImages
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
            // Handle resize if needed
        }
        
        func draw(in view: MTKView) {
            guard let currentDrawable = view.currentDrawable,
                  let ciImage = currentCIImage else {
                return
            }
            
            // Create a command buffer
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }
            
            // Render CIImage to Metal texture
            let bounds = CGRect(origin: .zero, size: view.drawableSize)
            ciContext.render(ciImage, 
                           to: currentDrawable.texture,
                           commandBuffer: commandBuffer,
                           bounds: bounds, 
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            
            // Present the drawable to the screen
            commandBuffer.present(currentDrawable)
            commandBuffer.commit()
        }
    }
} 