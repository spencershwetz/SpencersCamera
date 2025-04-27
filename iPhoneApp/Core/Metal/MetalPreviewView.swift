import MetalKit
import AVFoundation
import CoreVideo
import os.log

// Helper to convert FourCharCode to String
fileprivate func FourCCString(_ code: FourCharCode) -> String {
    let c = [ (code >> 24) & 0xff, (code >> 16) & 0xff, (code >> 8) & 0xff, code & 0xff ].map { Character(UnicodeScalar($0)!) }
    return String(c)
}

class MetalPreviewView: NSObject, MTKViewDelegate {
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "MetalPreviewView")
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var textureCache: CVMetalTextureCache!
    private var inFlightSemaphore = DispatchSemaphore(value: 1) // Single buffer for lower latency
    private let lutManager: LUTManager
    
    // Texture properties for different formats
    private var bgraTexture: MTLTexture?
    private var lumaTexture: MTLTexture?   // Y plane
    private var chromaTexture: MTLTexture? // CbCr plane
    private var currentPixelFormat: OSType = 0
    
    // Pipeline states
    private var rgbPipelineState: MTLRenderPipelineState!
    private var yuvPipelineState: MTLRenderPipelineState!
    
    // Keep track of the owning MTKView
    private weak var mtkView: MTKView?
    
    private var isLUTActiveBuffer: MTLBuffer! // Add buffer for LUT active flag
    private var isBT709Buffer: MTLBuffer! // Add buffer for BT.709 flag
    
    init(mtkView: MTKView, lutManager: LUTManager) {
        self.lutManager = lutManager
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
        
        // Create texture cache with high performance options
        let cacheAttributes: [String: Any] = [
            kCVMetalTextureCacheMaximumTextureAgeKey as String: 0
        ]
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, cacheAttributes as CFDictionary, device, nil, &textureCache)
        guard let unwrappedTextureCache = textureCache else {
            logger.critical("Could not create texture cache")
            fatalError("Could not create texture cache")
        }
        self.textureCache = unwrappedTextureCache
        
        // Setup render pipelines
        setupRenderPipelines()
        
        // Configure MTKView for maximum performance
        mtkView.delegate = self
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.presentsWithTransaction = false // Disable transaction for lower latency
        
        // Create uniform buffers with options for frequent updates
        var isLUTActiveValue: Bool = false
        isLUTActiveBuffer = device.makeBuffer(bytes: &isLUTActiveValue, 
                                            length: MemoryLayout<Bool>.size, 
                                            options: [.storageModeShared])
        
        var isBT709Value: Bool = false
        isBT709Buffer = device.makeBuffer(bytes: &isBT709Value, 
                                        length: MemoryLayout<Bool>.size, 
                                        options: [.storageModeShared])
        
        logger.info("MetalPreviewView initialized with device: \(self.device.name)")
    }
    
    // Renamed and modified to create both pipelines
    private func setupRenderPipelines() {
        guard let library = device.makeDefaultLibrary() else {
            logger.critical("Could not create Metal library")
            fatalError("Could not create Metal library")
        }
        
        // --- RGB Pipeline --- 
        let rgbPipelineDescriptor = MTLRenderPipelineDescriptor()
        rgbPipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        rgbPipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShaderRGB") // New shader name
        rgbPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            rgbPipelineState = try device.makeRenderPipelineState(descriptor: rgbPipelineDescriptor)
        } catch {
            logger.critical("Failed to create RGB render pipeline state: \(error.localizedDescription)")
            fatalError("Failed to create RGB render pipeline state: \(error.localizedDescription)")
        }
        
        // --- YUV Pipeline --- 
        let yuvPipelineDescriptor = MTLRenderPipelineDescriptor()
        yuvPipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        yuvPipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShaderYUV") // New shader name
        yuvPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm // Output is still BGRA
        
        do {
            yuvPipelineState = try device.makeRenderPipelineState(descriptor: yuvPipelineDescriptor)
        } catch {
            logger.critical("Failed to create YUV render pipeline state: \(error.localizedDescription)")
            fatalError("Failed to create YUV render pipeline state: \(error.localizedDescription)")
        }
    }
    
    func updateTexture(with sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.warning("Could not get pixel buffer from sample buffer")
            return
        }
        
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if pixelFormat != currentPixelFormat {
            CVMetalTextureCacheFlush(textureCache, 0)
            currentPixelFormat = pixelFormat
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Lock the pixel buffer for reading
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        var textureRef: CVMetalTexture?
        
        if pixelFormat == kCVPixelFormatType_32BGRA {
            // Reset BT.709 flag for non-BT.709 formats
            var isBT709Value = false
            memcpy(isBT709Buffer.contents(), &isBT709Value, MemoryLayout<Bool>.size)
            
            let result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .bgra8Unorm, width, height, 0, &textureRef
            )
            
            if result == kCVReturnSuccess, let unwrappedTextureRef = textureRef {
                bgraTexture = CVMetalTextureGetTexture(unwrappedTextureRef)
                lumaTexture = nil
                chromaTexture = nil
                
                // Trigger immediate draw
                mtkView?.draw()
            }
        } else if pixelFormat == 2016686642 { // 'x422' Apple Log
            // Reset BT.709 flag
            var isBT709Value = false
            memcpy(isBT709Buffer.contents(), &isBT709Value, MemoryLayout<Bool>.size)
            
            // Create Luma texture
            var lumaTextureRef: CVMetalTexture?
            let lumaResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .r16Unorm,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                0,
                &lumaTextureRef
            )
            
            // Create Chroma texture
            var chromaTextureRef: CVMetalTexture?
            let chromaResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .rg16Unorm,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                1,
                &chromaTextureRef
            )
            
            if lumaResult == kCVReturnSuccess && chromaResult == kCVReturnSuccess,
               let unwrappedLumaRef = lumaTextureRef,
               let unwrappedChromaRef = chromaTextureRef {
                lumaTexture = CVMetalTextureGetTexture(unwrappedLumaRef)
                chromaTexture = CVMetalTextureGetTexture(unwrappedChromaRef)
                bgraTexture = nil
                
                // Trigger immediate draw
                mtkView?.draw()
            }
        } else if pixelFormat == 875704438 { // '420v' - BT.709 video range
            // Set BT.709 flag for shader
            var isBT709Value = true
            memcpy(isBT709Buffer.contents(), &isBT709Value, MemoryLayout<Bool>.size)
            // Create Luma (Y) texture (Plane 0)
            var lumaTextureRef: CVMetalTexture?
            let lumaResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .r8Unorm,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                0,
                &lumaTextureRef
            )
            
            // Create Chroma (CbCr) texture (Plane 1)
            var chromaTextureRef: CVMetalTexture?
            let chromaResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .rg8Unorm,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                1,
                &chromaTextureRef
            )
            
            guard lumaResult == kCVReturnSuccess, let unwrappedLumaRef = lumaTextureRef,
                  chromaResult == kCVReturnSuccess, let unwrappedChromaRef = chromaTextureRef else {
                logger.warning("Failed to create 420v Metal textures from pixel buffer")
                return
            }
            
            // Update textures
            bgraTexture = nil
            lumaTexture = CVMetalTextureGetTexture(unwrappedLumaRef)
            chromaTexture = CVMetalTextureGetTexture(unwrappedChromaRef)
            
        } else if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { // '420v' format
            // Reset BT.709 flag when not BT.709
            var isBT709Value = false
            memcpy(isBT709Buffer.contents(), &isBT709Value, MemoryLayout<Bool>.size)
            // Create Luma (Y) texture (Plane 0)
            var lumaTextureRef: CVMetalTexture?
            let lumaResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .r8Unorm, // Use 8-bit single channel for luma
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                0, // Plane index 0
                &lumaTextureRef
            )
            
            // Create Chroma (CbCr) texture (Plane 1)
            var chromaTextureRef: CVMetalTexture?
            let chromaResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .rg8Unorm, // Use 8-bit 2-channel for chroma
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                1, // Plane index 1 for Chroma
                &chromaTextureRef
            )
            
            guard lumaResult == kCVReturnSuccess, let unwrappedLumaRef = lumaTextureRef,
                  chromaResult == kCVReturnSuccess, let unwrappedChromaRef = chromaTextureRef else {
                logger.warning("Failed to create YUV Metal textures from pixel buffer")
                return
            }
            
            bgraTexture = nil // Ensure BGRA texture is nil
            lumaTexture = CVMetalTextureGetTexture(unwrappedLumaRef)
            chromaTexture = CVMetalTextureGetTexture(unwrappedChromaRef)
            
            if lumaTexture == nil || chromaTexture == nil {
                logger.warning("Failed to get Metal textures from CVMetalTexture")
                return
            }
            
        } else {
            logger.warning("Ignoring unsupported pixel format: \(FourCCString(pixelFormat))")
            // Optionally clear textures if needed
            return
        }
        
        // No need to assign to currentTexture anymore
        // The draw method will use the specific textures based on currentPixelFormat
    }
    
    // MARK: - MTKViewDelegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        logger.debug("MTKView size changed to: \(String(describing: size))")
        // Flush texture cache when size changes
        // CVMetalTextureCacheFlush(textureCache, 0) // REMOVED Cache flush here, only needed before creating textures
    }
    
    func draw(in view: MTKView) {
        _ = inFlightSemaphore.wait(timeout: .now()) // Non-blocking wait
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            inFlightSemaphore.signal()
            return
        }
        
        // Set the pipeline state based on available textures
        if bgraTexture != nil {
            renderEncoder.setRenderPipelineState(rgbPipelineState)
            renderEncoder.setFragmentTexture(bgraTexture, index: 0)
        } else if lumaTexture != nil && chromaTexture != nil {
            renderEncoder.setRenderPipelineState(yuvPipelineState)
            renderEncoder.setFragmentTexture(lumaTexture, index: 0)
            renderEncoder.setFragmentTexture(chromaTexture, index: 1)
        } else {
            renderEncoder.endEncoding()
            inFlightSemaphore.signal()
            return
        }
        
        // Set LUT texture if available
        if let lutTexture = lutManager.currentLUTTexture {
            renderEncoder.setFragmentTexture(lutTexture, index: 2)
        }
        
        // Set uniform buffers
        renderEncoder.setFragmentBuffer(isLUTActiveBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentBuffer(isBT709Buffer, offset: 0, index: 1)
        
        // Draw quad with 4 vertices
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }
        
        commandBuffer.commit()
    }
    
    // ---> ADD DEINIT <--- 
    deinit {
        logger.info("MetalPreviewView DEINIT")
    }
    // ---> END DEINIT <--- 
} 