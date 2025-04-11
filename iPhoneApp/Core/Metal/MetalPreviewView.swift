import MetalKit
import AVFoundation
import os.log

class MetalPreviewView: NSObject, MTKViewDelegate {
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "MetalPreviewView")
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var renderPipelineState: MTLRenderPipelineState!
    private var textureCache: CVMetalTextureCache!
    private var currentTexture: MTLTexture?
    private var inFlightSemaphore = DispatchSemaphore(value: 3) // Triple buffer
    
    // Keep track of the owning MTKView
    private weak var mtkView: MTKView?
    
    init(mtkView: MTKView) {
        super.init()
        self.mtkView = mtkView
        
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            logger.critical("Metal is not supported on this device")
            fatalError("Metal is not supported on this device")
        }
        self.device = defaultDevice
        mtkView.device = self.device
        
        guard let newCommandQueue = self.device.makeCommandQueue() else {
            logger.critical("Could not create Metal command queue")
            fatalError("Could not create Metal command queue")
        }
        self.commandQueue = newCommandQueue
        
        // Create texture cache
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard let unwrappedTextureCache = textureCache else {
            logger.critical("Could not create texture cache")
            fatalError("Could not create texture cache")
        }
        self.textureCache = unwrappedTextureCache
        
        // Setup render pipeline
        setupRenderPipeline()
        
        // Configure MTKView
        mtkView.delegate = self
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false // Use continuous rendering
        mtkView.isPaused = false
        
        logger.info("MetalPreviewView initialized with device: \(self.device.name)")
    }
    
    private func setupRenderPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            logger.critical("Could not create Metal library")
            fatalError("Could not create Metal library")
        }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            logger.critical("Failed to create render pipeline state: \(error.localizedDescription)")
            fatalError("Failed to create render pipeline state: \(error.localizedDescription)")
        }
    }
    
    func updateTexture(with sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.warning("Could not get pixel buffer from sample buffer")
            return
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var textureRef: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &textureRef
        )
        
        guard result == kCVReturnSuccess,
              let unwrappedTextureRef = textureRef,
              let texture = CVMetalTextureGetTexture(unwrappedTextureRef) else {
            logger.warning("Failed to create Metal texture from pixel buffer")
            return
        }
        
        currentTexture = texture
        // Let MTKView handle drawing in its render loop
    }
    
    // MARK: - MTKViewDelegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        logger.debug("MTKView size changed to: \(String(describing: size))")
        // Flush texture cache when size changes
        CVMetalTextureCacheFlush(textureCache, 0)
    }
    
    func draw(in view: MTKView) {
        guard let currentDrawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let texture = currentTexture else {
            return
        }
        
        // Wait for a maximum of 1/60th of a second for the next buffer
        _ = inFlightSemaphore.wait(timeout: .now() + .milliseconds(16))
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        
        commandBuffer.label = "Preview Frame"
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            inFlightSemaphore.signal()
            return
        }
        
        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.addScheduledHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }
        
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }
} 