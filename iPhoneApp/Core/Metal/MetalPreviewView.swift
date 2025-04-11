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
        
        // Log the pixel buffer format
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let mediaTypeUInt = CMFormatDescriptionGetMediaType(CMSampleBufferGetFormatDescription(sampleBuffer)!)
        let mediaTypeStr = FourCCString(mediaTypeUInt) // Convert media type code
        let formatStr = FourCCString(pixelFormat) // Convert pixel format code
        logger.debug("Received pixel buffer: Format=\(formatStr) (\(pixelFormat)), MediaType=\(mediaTypeStr) (\(mediaTypeUInt))")
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Update current pixel format tracker
        if pixelFormat != currentPixelFormat {
            logger.info("Pixel format changed from \(FourCCString(self.currentPixelFormat)) to \(formatStr)")
            currentPixelFormat = pixelFormat
            // Clear old textures when format changes
            bgraTexture = nil
            lumaTexture = nil
            chromaTexture = nil
        }
        
        var textureRef: CVMetalTexture? // Temporary ref for cache function
        
        if pixelFormat == kCVPixelFormatType_32BGRA {
            // --- Handle BGRA --- 
            let result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .bgra8Unorm, width, height, 0, &textureRef
            )
            
            guard result == kCVReturnSuccess, let unwrappedTextureRef = textureRef else {
                logger.warning("Failed to create BGRA Metal texture from pixel buffer")
                return
            }
            bgraTexture = CVMetalTextureGetTexture(unwrappedTextureRef)
            lumaTexture = nil // Ensure YUV textures are nil
            chromaTexture = nil
            
        } else if pixelFormat == 2016686642 {
            // --- Handle YUV 422 10-bit Bi-Planar (Apple Log 'x422') ---
            
            // Create Luma (Y) texture (Plane 0)
            var lumaTextureRef: CVMetalTexture?
            let lumaResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .r16Unorm, // 16-bit single channel for 10-bit luma
                width, height, 0, // Plane index 0
                &lumaTextureRef
            )
            
            // Create Chroma (CbCr) texture (Plane 1)
            // Note: Chroma dimensions are half width/height for 4:2:0
            let chromaTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rg8Unorm,  // <--- CHANGE: Use 8-bit per component format (2 bytes total)
                width: width,           
                height: height,
                mipmapped: false
            )
            var chromaTextureRef: CVMetalTexture?
            let chromaResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .rg8Unorm, // <--- FIX: Pass the correct pixel format here
                width, height, 1, // Plane index 1 for Chroma
                &chromaTextureRef
            )
            
            guard lumaResult == kCVReturnSuccess, let unwrappedLumaRef = lumaTextureRef,
                  chromaResult == kCVReturnSuccess, let unwrappedChromaRef = chromaTextureRef else {
                logger.warning("Failed to create YUV Metal textures. Luma result: \(lumaResult), Chroma result: \(chromaResult)")
                return
            }
            
            lumaTexture = CVMetalTextureGetTexture(unwrappedLumaRef)
            chromaTexture = CVMetalTextureGetTexture(unwrappedChromaRef)
            bgraTexture = nil // Ensure BGRA texture is nil
            
            if let chromaTex = chromaTexture {
                logger.debug("Creating Chroma Texture (x422): Width=\(width), Height=\(height)")
                let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                let expectedChromaBytesPerRow = width * 2 // <--- CHANGE: rg8Unorm = 2 channels * 8 bits = 16 bits = 2 bytes per pixel
                logger.debug("Luma BytesPerRow=\(lumaBytesPerRow)")
                logger.debug("Chroma BytesPerRow (Reported)=\(chromaBytesPerRow), Expected=\(expectedChromaBytesPerRow)")
                
                let chromaRegion = MTLRegionMake2D(0, 0, width, height)
            }
            
        } else {
            logger.error("Unsupported pixel format: \(formatStr) (\(pixelFormat))")
            // Clear all textures if unsupported format is received
            bgraTexture = nil
            lumaTexture = nil
            chromaTexture = nil
            return
        }
        
        // No need to assign to currentTexture anymore
        // The draw method will use the specific textures based on currentPixelFormat
    }
    
    // MARK: - MTKViewDelegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        logger.debug("MTKView size changed to: \(String(describing: size))")
        // Flush texture cache when size changes
        CVMetalTextureCacheFlush(textureCache, 0)
    }
    
    func draw(in view: MTKView) {
        guard let currentDrawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            // Textures might not be ready yet, or drawable isn't available
            return
        }
        
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
        
        guard let lutTexture = lutManager.currentLUTTexture else {
             logger.warning("LUT Texture is nil, cannot draw.")
             renderEncoder.endEncoding()
             commandBuffer.commit() // Commit empty command buffer
             inFlightSemaphore.signal()
             return
         }
        
        // Select pipeline and bind textures based on the current format
        if currentPixelFormat == kCVPixelFormatType_32BGRA, let texture = bgraTexture {
            renderEncoder.setRenderPipelineState(rgbPipelineState)
            renderEncoder.setFragmentTexture(texture, index: 0)    // BGRA texture
            renderEncoder.setFragmentTexture(lutTexture, index: 1) // LUT texture
        } else if currentPixelFormat == 2016686642,
                  let yTexture = lumaTexture, let cbcrTexture = chromaTexture {
            renderEncoder.setRenderPipelineState(yuvPipelineState)
            renderEncoder.setFragmentTexture(yTexture, index: 0)    // Luma (Y) texture
            renderEncoder.setFragmentTexture(cbcrTexture, index: 1) // Chroma (CbCr) texture
            renderEncoder.setFragmentTexture(lutTexture, index: 2)   // LUT texture
        } else {
            //logger.trace("No valid textures available for current format: \(FourCCString(currentPixelFormat))")
            // Don't draw anything if the textures for the current format aren't ready
            renderEncoder.endEncoding()
            commandBuffer.commit() // Commit empty command buffer
            inFlightSemaphore.signal()
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
} 