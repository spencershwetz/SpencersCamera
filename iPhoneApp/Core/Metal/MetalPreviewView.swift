import MetalKit
import AVFoundation
import os.log

class MetalPreviewView: NSObject, MTKViewDelegate {
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "MetalPreviewView")
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    
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
        
        mtkView.delegate = self
        mtkView.colorPixelFormat = .bgra8Unorm // Common format for previews
        mtkView.framebufferOnly = true // Optimize if not sampling the drawable
        logger.info("MetalPreviewView initialized with device: \(self.device.name)")
    }
    
    // MARK: - MTKViewDelegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle view size changes if needed (e.g., update projection matrix)
        logger.debug("MTKView size changed to: \(String(describing: size))")
    }
    
    func draw(in view: MTKView) {
        // --- Step 1: Clear to Red --- 
        guard let drawable: CAMetalDrawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            logger.warning("Could not get drawable or render pass descriptor")
            return
        }
        
        // Modify the clear color
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        // Ensure load action is clear
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store // Store the cleared result
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            logger.warning("Could not create command buffer")
            return
        }
        commandBuffer.label = "FrameCommandBuffer"
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            logger.warning("Could not create render command encoder")
            return
        }
        renderEncoder.label = "FrameRenderEncoder"
        
        // No drawing commands needed yet, just clearing
        
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
} 