import UIKit
import AVFoundation
import MetalKit
import os.log

class CameraViewController: UIViewController {
    private let previewView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }()
    
    private var metalView: MTKView?
    private var ciContext: CIContext?
    private var commandQueue: MTLCommandQueue?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraViewController")
    
    // Cache for texture conversion
    private var textureCache: CVMetalTextureCache?
    private var currentPixelFormat: OSType = 0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupMetal()
        setupCamera()
    }
    
    private func setupUI() {
        view.addSubview(previewView)
        previewView.frame = view.bounds
        
        // Add metal view for efficient rendering
        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.error("Failed to create Metal device")
            return
        }
        
        let metalView = MTKView(frame: view.bounds, device: device)
        self.metalView = metalView
        metalView.framebufferOnly = false
        metalView.delegate = self
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = 60
        metalView.colorPixelFormat = .bgra8Unorm
        
        // Create texture cache for efficient texture conversion
        var textureCache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) != kCVReturnSuccess {
            logger.error("Failed to create texture cache")
        }
        self.textureCache = textureCache
        
        previewView.addSubview(metalView)
        metalView.frame = previewView.bounds
        
        logger.info("UI setup completed")
    }
    
    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.error("Failed to create Metal device")
            return
        }
        
        commandQueue = device.makeCommandQueue()
        
        // Create high-performance CI context
        let options = [CIContextOption.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      CIContextOption.useSoftwareRenderer: false,
                      CIContextOption.cacheIntermediates: false] as [CIContextOption : Any]
        
        ciContext = CIContext(mtlDevice: device, options: options)
        logger.info("Metal setup completed")
    }
    
    private func setupCamera() {
        Task {
            do {
                try await CameraManager.shared.setupCamera()
                CameraManager.shared.delegate = self
                CameraManager.shared.configurePreview(in: previewView)
                logger.info("Camera setup completed successfully")
            } catch {
                logger.error("Camera setup failed: \(error.localizedDescription)")
            }
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewView.frame = view.bounds
        metalView?.frame = previewView.bounds
        CameraManager.shared.updateOrientation()
    }
}

// MARK: - MTKViewDelegate
extension CameraViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle size changes if needed
    }
    
    func draw(in view: MTKView) {
        // Metal drawing handled in camera delegate
    }
}

// MARK: - CameraManagerDelegate
extension CameraViewController: CameraManagerDelegate {
    func cameraManager(_ manager: CameraManager, didReceiveFrame pixelBuffer: CVPixelBuffer) {
        guard let metalView = metalView,
              let drawable = metalView.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext = ciContext else {
            return
        }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Scale to fit while maintaining aspect ratio
        let scaleX = metalView.drawableSize.width / ciImage.extent.width
        let scaleY = metalView.drawableSize.height / ciImage.extent.height
        let scale = min(scaleX, scaleY)
        
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        // Center the image
        let centeredImage = scaledImage.transformed(by: CGAffineTransform(translationX: 
            (metalView.drawableSize.width - scaledImage.extent.width) / 2,
            y: (metalView.drawableSize.height - scaledImage.extent.height) / 2))
        
        // Render efficiently with Metal
        ciContext.render(centeredImage,
                        to: drawable.texture,
                        commandBuffer: commandBuffer,
                        bounds: CGRect(origin: .zero, size: metalView.drawableSize),
                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
} 