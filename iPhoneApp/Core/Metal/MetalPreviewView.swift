import MetalKit
import AVFoundation
import CoreVideo
import os.log

// Helper to convert FourCharCode to String
fileprivate func FourCCString(_ code: FourCharCode) -> String {
    let c = [ (code >> 24) & 0xff, (code >> 16) & 0xff, (code >> 8) & 0xff, code & 0xff ].compactMap { UnicodeScalar($0) }.map { Character($0) }
    return String(c)
}

class MetalPreviewView: NSObject, MTKViewDelegate {
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.spencerscamera", category: "MetalPreviewView")
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var inFlightSemaphore = DispatchSemaphore(value: 3) // Triple buffering
    private let lutManager: LUTManager
    private var rotationAngle: Double = 0.0 {
        didSet {
            if abs(oldValue - rotationAngle) > 0.01 { // Only update if change is significant
                guard let buffer = rotationBuffer else { return }
                var rotation = Float(rotationAngle * Double.pi / 180.0)
                memcpy(buffer.contents(), &rotation, MemoryLayout<Float>.size)
            }
        }
    }
    private var rotationBuffer: MTLBuffer?
    
    // Texture properties for different formats
    private var bgraTexture: MTLTexture?
    private var lumaTexture: MTLTexture?   // Y plane
    private var chromaTexture: MTLTexture? // CbCr plane
    private var currentPixelFormat: OSType = 0
    
    // Pipeline states
    private var rgbPipelineState: MTLRenderPipelineState?
    private var yuvPipelineState: MTLRenderPipelineState?
    
    // Keep track of the owning MTKView
    private weak var mtkView: MTKView?
    
    private var isLUTActiveBuffer: MTLBuffer? // Add buffer for LUT active flag
    private var isBT709Buffer: MTLBuffer? // Add buffer for BT.709 flag
    
    // Frame synchronization
    private let frameQueue = DispatchQueue(label: "com.camera.frameQueue", qos: .userInteractive)
    private var needsNewFrame = true
    
    // Add throttling for rotation updates
    private var lastRotationUpdate: CFTimeInterval = 0
    private let rotationUpdateThreshold: CFTimeInterval = 1.0 / 30.0 // 30fps max for rotation updates
    
    // Track previously bound LUT texture to reduce logging
    private var previouslyBoundLUTTexture: MTLTexture?
    
    // Frame counter for texture cache management
    private var frameCounter = 0
    
    init?(mtkView: MTKView, lutManager: LUTManager) {
        self.lutManager = lutManager
        super.init()
        self.mtkView = mtkView
        
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            logger.critical("Metal is not supported on this device")
            return nil
        }
        self.device = defaultDevice
        mtkView.device = self.device
        
        guard let newCommandQueue = defaultDevice.makeCommandQueue() else {
            logger.critical("Could not create Metal command queue")
            return nil
        }
        self.commandQueue = newCommandQueue
        
        // Create texture cache with high performance options
        let cacheAttributes: [String: Any] = [
            kCVMetalTextureCacheMaximumTextureAgeKey as String: 0
        ]
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, cacheAttributes as CFDictionary, defaultDevice, nil, &textureCache)
        guard let unwrappedTextureCache = textureCache else {
            logger.critical("Could not create texture cache")
            return nil
        }
        self.textureCache = unwrappedTextureCache
        
        // Create rotation buffer
        var initialRotation: Float = 0.0
        guard let rotBuffer = defaultDevice.makeBuffer(bytes: &initialRotation,
                                         length: MemoryLayout<Float>.size,
                                         options: [.storageModeShared]) else {
            logger.critical("Could not create rotation buffer")
            return nil
        }
        rotationBuffer = rotBuffer
        
        // Setup render pipelines
        guard setupRenderPipelines() else {
            logger.critical("Failed to setup render pipelines")
            return nil
        }
        
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
        guard let lutActiveBuffer = defaultDevice.makeBuffer(bytes: &isLUTActiveValue, 
                                            length: MemoryLayout<Bool>.size, 
                                            options: [.storageModeShared]) else {
            logger.critical("Could not create LUT active buffer")
            return nil
        }
        isLUTActiveBuffer = lutActiveBuffer
        
        var isBT709Value: Bool = false
        guard let bt709Buffer = defaultDevice.makeBuffer(bytes: &isBT709Value, 
                                        length: MemoryLayout<Bool>.size, 
                                        options: [.storageModeShared]) else {
            logger.critical("Could not create BT709 buffer")
            return nil
        }
        isBT709Buffer = bt709Buffer
        
        // Add observer for LUT changes
        lutManager.onLUTChanged = { [weak self] isActive in
            guard let self = self,
                  let buffer = self.isLUTActiveBuffer else { return }
            var isLUTActiveValue = isActive
            memcpy(buffer.contents(), &isLUTActiveValue, MemoryLayout<Bool>.size)
        }
        
        logger.info("MetalPreviewView initialized with device: \(defaultDevice.name)")
    }
    
    public func prepareForNewSession() {
        logger.info("Preparing MetalPreviewView for new session. Flushing texture cache and resetting textures.")
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        // Nil out textures to ensure they are recreated
        self.bgraTexture = nil
        self.lumaTexture = nil
        self.chromaTexture = nil
        self.currentPixelFormat = 0 // Force re-evaluation of pixel format and potentially another flush on first new frame
        self.frameCounter = 0 // Reset periodic flush counter
        
        // It might also be beneficial to clear the MTKView's drawable if possible,
        // though simply not drawing until a new valid frame arrives might be sufficient.
        // Clearing the view to a solid color (e.g., black) could prevent a flash of old content.
        // However, this needs to be done carefully within the MTKView's drawing cycle.
        // For now, focusing on cache and texture state.
        logger.info("MetalPreviewView new session preparation complete.")
    }
    
    // Renamed and modified to create both pipelines
    private func setupRenderPipelines() -> Bool {
        guard let device = device,
              let library = device.makeDefaultLibrary() else {
            logger.critical("Could not create Metal library")
            return false
        }
        
        // --- RGB Pipeline --- 
        let rgbPipelineDescriptor = MTLRenderPipelineDescriptor()
        rgbPipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShaderWithRotation")
        rgbPipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShaderRGB")
        rgbPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            rgbPipelineState = try device.makeRenderPipelineState(descriptor: rgbPipelineDescriptor)
        } catch {
            logger.critical("Failed to create RGB render pipeline state: \(error.localizedDescription)")
            return false
        }
        
        // --- YUV Pipeline --- 
        let yuvPipelineDescriptor = MTLRenderPipelineDescriptor()
        yuvPipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShaderWithRotation")
        yuvPipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShaderYUV")
        yuvPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            yuvPipelineState = try device.makeRenderPipelineState(descriptor: yuvPipelineDescriptor)
        } catch {
            logger.critical("Failed to create YUV render pipeline state: \(error.localizedDescription)")
            return false
        }
        
        return true
    }
    
    func updateTexture(with sampleBuffer: CMSampleBuffer) {
        // Wait for a rendering slot to become available
        inFlightSemaphore.wait()
        
        frameQueue.async { [weak self] in
            guard let self = self else {
                self?.inFlightSemaphore.signal()
                return
            }
            
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                self.logger.warning("Could not get pixel buffer from sample buffer")
                self.inFlightSemaphore.signal()
                return
            }
            
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            // Always flush the texture cache when the format changes
            if pixelFormat != self.currentPixelFormat {
                if let cache = self.textureCache {
                    CVMetalTextureCacheFlush(cache, 0)
                }
                self.currentPixelFormat = pixelFormat
            } else {
                // Periodically flush cache even when format doesn't change (every 30 frames)
                self.frameCounter += 1
                if self.frameCounter >= 30 {
                    if let cache = self.textureCache {
                        CVMetalTextureCacheFlush(cache, 0)
                    }
                    self.frameCounter = 0
                }
            }
            
            // Lock the pixel buffer for reading
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { 
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                self.inFlightSemaphore.signal()
            }
            
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            
            var textureUpdated = false
            
            if pixelFormat == kCVPixelFormatType_32BGRA {
                // Reset BT.709 flag for non-BT.709 formats
                var isBT709Value = false
                if let contents = self.isBT709Buffer?.contents() {
                    memcpy(contents, &isBT709Value, MemoryLayout<Bool>.size)
                }
                
                guard let textureCache = self.textureCache else {
                    self.inFlightSemaphore.signal()
                    return
                }
                var textureRef: CVMetalTexture?
                let result = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                    .bgra8Unorm, width, height, 0, &textureRef
                )
                
                if result == kCVReturnSuccess, let unwrappedTextureRef = textureRef {
                    self.bgraTexture = CVMetalTextureGetTexture(unwrappedTextureRef)
                    self.lumaTexture = nil
                    self.chromaTexture = nil
                    textureUpdated = true
                }
            } else if pixelFormat == 2016686642 { // 'x422' Apple Log
                // Reset BT.709 flag
                var isBT709Value = false
                if let contents = self.isBT709Buffer?.contents() {
                    memcpy(contents, &isBT709Value, MemoryLayout<Bool>.size)
                }
                
                guard let textureCache = self.textureCache else {
                    self.inFlightSemaphore.signal()
                    return
                }
                
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
                    self.lumaTexture = CVMetalTextureGetTexture(unwrappedLumaRef)
                    self.chromaTexture = CVMetalTextureGetTexture(unwrappedChromaRef)
                    self.bgraTexture = nil
                    textureUpdated = true
                }
            } else if pixelFormat == 875704438 { // '420v' - BT.709 video range
                // Set BT.709 flag for shader
                var isBT709Value = true
                if let contents = self.isBT709Buffer?.contents() {
                    memcpy(contents, &isBT709Value, MemoryLayout<Bool>.size)
                }
                
                guard let textureCache = self.textureCache else {
                    self.inFlightSemaphore.signal()
                    return
                }
                
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
                    self.logger.warning("Failed to create 420v Metal textures from pixel buffer")
                    return
                }
                
                // Update textures
                self.bgraTexture = nil
                self.lumaTexture = CVMetalTextureGetTexture(unwrappedLumaRef)
                self.chromaTexture = CVMetalTextureGetTexture(unwrappedChromaRef)
                textureUpdated = true
            } else if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { // '420v' format
                // Reset BT.709 flag when not BT.709
                var isBT709Value = false
                if let contents = self.isBT709Buffer?.contents() {
                    memcpy(contents, &isBT709Value, MemoryLayout<Bool>.size)
                }
                
                guard let textureCache = self.textureCache else {
                    self.inFlightSemaphore.signal()
                    return
                }
                
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
                    self.logger.warning("Failed to create YUV Metal textures from pixel buffer")
                    return
                }
                
                self.bgraTexture = nil // Ensure BGRA texture is nil
                self.lumaTexture = CVMetalTextureGetTexture(unwrappedLumaRef)
                self.chromaTexture = CVMetalTextureGetTexture(unwrappedChromaRef)
                
                if self.lumaTexture == nil || self.chromaTexture == nil {
                    self.logger.warning("Failed to get Metal textures from CVMetalTexture")
                    return
                }
                textureUpdated = true
            } else {
                self.logger.warning("Ignoring unsupported pixel format: \(FourCCString(pixelFormat))")
                // Optionally clear textures if needed
                return
            }
            
            if textureUpdated {
                DispatchQueue.main.async {
                    self.mtkView?.draw()
                }
            }
        }
    }
    
    func updateRotation(angle: Double) {
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastRotationUpdate >= rotationUpdateThreshold else {
            return // Skip update if too soon
        }
        
        if abs(rotationAngle - angle) > 0.01 { // Only update if change is significant
            rotationAngle = angle
            lastRotationUpdate = currentTime
            
            // Only trigger a draw if we're not already processing a frame
            if needsNewFrame {
                DispatchQueue.main.async { [weak self] in
                    self?.mtkView?.draw()
                }
            }
        }
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
            return
        }
        
        // Get command buffer from the command queue
        guard let commandQueue = commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            logger.error("Failed to create command buffer")
            return
        }
        
        // Create render command encoder
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            logger.error("Failed to create render command encoder")
            return
        }
        
        // Set the render pipeline state based on texture format
        if let bgraTexture = self.bgraTexture {
            guard let rgbPipeline = rgbPipelineState else { 
                renderEncoder.endEncoding()
                commandBuffer.commit()
                return
            }
            renderEncoder.setRenderPipelineState(rgbPipeline)
            renderEncoder.setFragmentTexture(bgraTexture, index: 0)
            if let lutTexture = lutManager.currentLUTTexture {
                // Only log if the texture actually changed
                if lutTexture !== previouslyBoundLUTTexture {
                    logger.debug("Binding LUT texture (RGB path): \\(lutTexture.width, privacy: .public)x\\(lutTexture.height, privacy: .public)x\\(lutTexture.depth, privacy: .public)")
                    previouslyBoundLUTTexture = lutTexture
                }
                renderEncoder.setFragmentTexture(lutTexture, index: 1)
            } else {
                // Log if a LUT was previously bound but is now nil
                if previouslyBoundLUTTexture != nil {
                     logger.debug("Unbinding LUT texture (RGB path)")
                     previouslyBoundLUTTexture = nil
                }
               // logger.debug("No LUT texture available (RGB path)") // Reduced noise
            }
            renderEncoder.setFragmentBuffer(isLUTActiveBuffer, offset: 0, index: 0)
        } else if let lumaTexture = self.lumaTexture, let chromaTexture = self.chromaTexture {
            guard let yuvPipeline = yuvPipelineState else {
                renderEncoder.endEncoding()
                commandBuffer.commit()
                return
            }
            renderEncoder.setRenderPipelineState(yuvPipeline)
            renderEncoder.setFragmentTexture(lumaTexture, index: 0)
            renderEncoder.setFragmentTexture(chromaTexture, index: 1)
            if let lutTexture = lutManager.currentLUTTexture {
                // Only log if the texture actually changed
                if lutTexture !== previouslyBoundLUTTexture {
                    logger.debug("Binding LUT texture (YUV path): \\(lutTexture.width, privacy: .public)x\\(lutTexture.height, privacy: .public)x\\(lutTexture.depth, privacy: .public)")
                    previouslyBoundLUTTexture = lutTexture
                }
                renderEncoder.setFragmentTexture(lutTexture, index: 2)
            } else {
                 // Log if a LUT was previously bound but is now nil
                if previouslyBoundLUTTexture != nil {
                     logger.debug("Unbinding LUT texture (YUV path)")
                     previouslyBoundLUTTexture = nil
                }
                // logger.debug("No LUT texture available (YUV path)") // Reduced noise
            }
            renderEncoder.setFragmentBuffer(isLUTActiveBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentBuffer(isBT709Buffer, offset: 0, index: 1)
        } else {
            renderEncoder.endEncoding()
            commandBuffer.commit()
            return
        }
        
        // Set rotation buffer
        renderEncoder.setVertexBuffer(rotationBuffer, offset: 0, index: 1)
        
        // Draw the quad
        renderEncoder.drawPrimitives(type: MTLPrimitiveType.triangleStrip, vertexStart: 0, vertexCount: 4)
        
        // End encoding
        renderEncoder.endEncoding()
        
        // Add completion handler
        commandBuffer.addCompletedHandler { [weak self] (_: MTLCommandBuffer) in
            self?.needsNewFrame = true
        }
        
        // Present and commit
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }
    
    // ---> ADD DEINIT <--- 
    deinit {
        logger.info("MetalPreviewView DEINIT")
        // Flush the texture cache to release all cached textures
        if let cache = textureCache { // Ensure textureCache is not nil
            CVMetalTextureCacheFlush(cache, 0)
            logger.info("Flushed CVMetalTextureCache in deinit.")
        }
        // Any other cleanup if necessary
    }
    // ---> END DEINIT <--- 
} 