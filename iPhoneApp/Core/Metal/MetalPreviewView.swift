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
    private var inFlightSemaphore = DispatchSemaphore(value: 3) // Triple buffer
    private let lutManager: LUTManager
    
    // Texture properties for different formats
    private var bgraTexture: MTLTexture?
    private var lumaTexture: MTLTexture?   // Y plane
    private var chromaTexture: MTLTexture? // CbCr plane
    private var currentPixelFormat: OSType = 0
    
    // Pipeline states
    private var rgbPipelineState: MTLRenderPipelineState!
    private var yuvPipelineState: MTLRenderPipelineState! // To be created later
    
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
        
        // Create texture cache
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard let unwrappedTextureCache = textureCache else {
            logger.critical("Could not create texture cache")
            fatalError("Could not create texture cache")
        }
        self.textureCache = unwrappedTextureCache
        
        // Setup render pipelines (we'll create two now)
        setupRenderPipelines()
        
        // Configure MTKView
        mtkView.delegate = self
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false // Use continuous rendering
        mtkView.isPaused = false
        
        // Create uniform buffers
        var isLUTActiveValue: Bool = false
        isLUTActiveBuffer = device.makeBuffer(bytes: &isLUTActiveValue, length: MemoryLayout<Bool>.size, options: [])
        
        var isBT709Value: Bool = false
        isBT709Buffer = device.makeBuffer(bytes: &isBT709Value, length: MemoryLayout<Bool>.size, options: [])
        
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
        
        // Log the pixel buffer format
        let mediaTypeUInt = CMFormatDescriptionGetMediaType(CMSampleBufferGetFormatDescription(sampleBuffer)!)
        let _ = FourCCString(mediaTypeUInt) // Convert media type code (Marked as unused)
        let formatStr = FourCCString(pixelFormat) // Convert pixel format code
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Update current pixel format tracker
        if pixelFormat != currentPixelFormat {
            logger.info("Pixel format changed from \(FourCCString(self.currentPixelFormat)) to \(formatStr)")
            // Clear old textures when format changes
            bgraTexture = nil
            lumaTexture = nil
            chromaTexture = nil
        }
        
        var textureRef: CVMetalTexture? // Temporary ref for cache function
        
        if pixelFormat == kCVPixelFormatType_32BGRA {
            // Reset BT.709 flag for non-BT.709 formats
            var isBT709Value = false
            memcpy(isBT709Buffer.contents(), &isBT709Value, MemoryLayout<Bool>.size)
            // --- Handle BGRA --- 
            let result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .bgra8Unorm, width, height, 0, &textureRef
            )
            
            // ---> LOG TEXTURE CREATION RESULT <---
            if result != kCVReturnSuccess {
                logger.error("BGRA Texture Creation FAILED: Result Code \(result)")
            } else {
                // logger.trace("BGRA Texture Creation SUCCESS") // Optional success log
            }
            // ---> END LOG <---

            guard result == kCVReturnSuccess, let unwrappedTextureRef = textureRef else {
                logger.warning("Failed to create BGRA Metal texture from pixel buffer")
                return
            }
            bgraTexture = CVMetalTextureGetTexture(unwrappedTextureRef)
            lumaTexture = nil // Ensure YUV textures are nil
            chromaTexture = nil
            
        } else if pixelFormat == 2016686642 { // 'x422' 10-bit Biplanar Apple Log format
            // Reset BT.709 flag for Apple Log format
            var isBT709Value = false
            memcpy(isBT709Buffer.contents(), &isBT709Value, MemoryLayout<Bool>.size)
            // --- Handle YUV 422 10-bit Bi-Planar (Apple Log 'x422') ---
            
            // Create Luma (Y) texture (Plane 0)
            var lumaTextureRef: CVMetalTexture?
            let lumaResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .r16Unorm, // Use 16-bit single channel for 10-bit luma
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                0, // Plane index 0
                &lumaTextureRef
            )
            
            // ---> LOG TEXTURE CREATION RESULT <---
            if lumaResult != kCVReturnSuccess {
                logger.error("YUV Luma Texture Creation FAILED: Result Code \(lumaResult)")
            }
            // ---> END LOG <---
            
            // Create Chroma (CbCr) texture (Plane 1)
            var chromaTextureRef: CVMetalTexture?
            let chromaResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .rg16Unorm, // Use 16-bit 2-channel for 10-bit chroma
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                1, // Plane index 1 for Chroma
                &chromaTextureRef
            )
            
            // ---> LOG TEXTURE CREATION RESULT <---
            if chromaResult != kCVReturnSuccess {
                logger.error("YUV Chroma Texture Creation FAILED: Result Code \(chromaResult)")
            }
            // ---> END LOG <---
            
            guard lumaResult == kCVReturnSuccess, let unwrappedLumaRef = lumaTextureRef,
                  chromaResult == kCVReturnSuccess, let unwrappedChromaRef = chromaTextureRef else {
                logger.warning("Failed to create YUV Metal textures. Luma result: \(lumaResult), Chroma result: \(chromaResult)")
                return
            }
            
            // Assign the textures correctly
            lumaTexture = CVMetalTextureGetTexture(unwrappedLumaRef) 
            chromaTexture = CVMetalTextureGetTexture(unwrappedChromaRef)
            bgraTexture = nil // Ensure BGRA texture is nil
            
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
            logger.warning("Ignoring unsupported pixel format: \(formatStr)")
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
        guard let currentDrawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            // Textures might not be ready yet, or drawable isn't available
            return
        }
        
        // Update LUT active flag before each frame
        var isLUTActiveFlag: Bool = (lutManager.currentLUTTexture != nil)
        memcpy(isLUTActiveBuffer.contents(), &isLUTActiveFlag, MemoryLayout<Bool>.size)
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        commandBuffer.label = "Preview Frame"
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        let lutTexture = lutManager.currentLUTTexture // May be nil
        
        // Determine which pipeline to use
        if let bgraTex = bgraTexture {
            renderEncoder.setRenderPipelineState(rgbPipelineState)
            renderEncoder.setFragmentTexture(bgraTex, index: 0)
            if let lutTex = lutTexture {
                renderEncoder.setFragmentTexture(lutTex, index: 1)
            }
            // No uniform buffers needed for RGB shader
        } else if let lumaTex = lumaTexture, let chromaTex = chromaTexture {
            renderEncoder.setRenderPipelineState(yuvPipelineState)
            renderEncoder.setFragmentTexture(lumaTex, index: 0)
            renderEncoder.setFragmentTexture(chromaTex, index: 1)
            if let lutTex = lutTexture {
                renderEncoder.setFragmentTexture(lutTex, index: 2)
            }
            // Set uniform buffers
            renderEncoder.setFragmentBuffer(isLUTActiveBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentBuffer(isBT709Buffer, offset: 0, index: 1)
        } else {
            renderEncoder.endEncoding()
            commandBuffer.commit() // Commit empty command buffer
            return
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.addScheduledHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }
        
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }
    
    // ---> ADD DEINIT <--- 
    deinit {
        logger.info("MetalPreviewView DEINIT")
    }
    // ---> END DEINIT <--- 
} 