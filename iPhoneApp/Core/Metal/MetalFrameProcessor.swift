import Foundation
import Metal
import CoreVideo
import OSLog

class MetalFrameProcessor {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "MetalFrameProcessor")
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var computePipelineStateRGB: MTLComputePipelineState?
    private var computePipelineStateYUV: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    
    var lutTexture: MTLTexture? // Publicly settable LUT texture

    init?() {
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            logger.error("Metal is not supported on this device.")
            return nil
        }
        device = defaultDevice
        
        guard let queue = device.makeCommandQueue() else {
            logger.error("Failed to create Metal command queue.")
            return nil
        }
        commandQueue = queue
        
        // Setup Texture Cache
        var cache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) != kCVReturnSuccess {
            logger.error("Failed to create Metal texture cache.")
            return nil
        }
        textureCache = cache
        
        // Load the compute kernels
        do {
            let library = try device.makeDefaultLibrary(bundle: .main)
            // Load RGB kernel
            guard let rgbKernelFunction = library.makeFunction(name: "applyLUTComputeRGB") else {
                logger.error("Failed to find kernel function 'applyLUTComputeRGB'.")
                return nil
            }
            computePipelineStateRGB = try device.makeComputePipelineState(function: rgbKernelFunction)
            logger.debug("Successfully created compute pipeline state for RGB LUT application.")

            // Load YUV kernel ( Placeholder name - will be created in metal file next)
            guard let yuvKernelFunction = library.makeFunction(name: "applyLUTComputeYUV") else {
                logger.error("Failed to find kernel function 'applyLUTComputeYUV'. Make sure it's added to PreviewShaders.metal")
                // Don't fail init entirely, maybe only RGB processing will be available
                 logger.warning("YUV compute kernel not found. LUT bake-in might not work for Apple Log.")
                // return nil // Optional: Uncomment if YUV MUST be supported
                return nil // Ensure guard body exits
            }
            computePipelineStateYUV = try device.makeComputePipelineState(function: yuvKernelFunction)
            logger.debug("Successfully created compute pipeline state for YUV LUT application.")

        } catch {
            logger.error("Failed to create compute pipeline state: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Processes a CVPixelBuffer using the appropriate Metal compute kernel based on pixel format.
    /// - Parameter pixelBuffer: The input CVPixelBuffer.
    /// - Returns: A new CVPixelBuffer (always BGRA format) with the LUT applied, or nil if processing fails.
    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
         guard let cache = textureCache else {
            logger.error("Metal texture cache not initialized.")
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // --- Select Kernel and Prepare Input Textures ---
        var inputTextureY: MTLTexture? // For Y plane (YUV) or single plane (RGB)
        var inputTextureCbCr: MTLTexture? // For CbCr plane (YUV only)
        var pipelineState: MTLComputePipelineState?
        var requiresYUVProcessing = false

        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            logger.trace("Processing BGRA frame.")
            pipelineState = computePipelineStateRGB
            var cvTextureIn: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTextureIn)
            guard status == kCVReturnSuccess, let cvTexIn = cvTextureIn else {
                logger.error("Failed to create input BGRA Metal texture: \(status)")
                CVMetalTextureCacheFlush(cache, 0)
                return nil
            }
            inputTextureY = CVMetalTextureGetTexture(cvTexIn) // Use Y texture slot for single plane

        case kCVPixelFormatType_422YpCbCr10: // Apple Log 10-bit 4:2:2 YpCbCr ('v210')
             logger.trace("Processing YUV ('v210') frame.")
             requiresYUVProcessing = true
             pipelineState = computePipelineStateYUV

             // Texture for Y plane (Plane 0) - Use r16Unorm for 10/12/16-bit Y data
             var cvTextureY: CVMetalTexture?
             var status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .r16Unorm, width, height, 0, &cvTextureY)
             guard status == kCVReturnSuccess, let cvTexY = cvTextureY else {
                 logger.error("Failed to create input Y Metal texture (r16Unorm) for v210: \(status)")
                 CVMetalTextureCacheFlush(cache, 0)
                 return nil
             }
             inputTextureY = CVMetalTextureGetTexture(cvTexY)

             // Texture for CbCr plane (Plane 1) - Use rg16Unorm for 10/12/16-bit UV data
             var cvTextureCbCr: CVMetalTexture?
            // Note: Width for CbCr plane is half the Luma width in 4:2:2
             status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .rg16Unorm, width / 2, height, 1, &cvTextureCbCr)
             guard status == kCVReturnSuccess, let cvTexCbCr = cvTextureCbCr else {
                 logger.error("Failed to create input CbCr Metal texture (rg16Unorm) for v210: \(status)")
                 CVMetalTextureCacheFlush(cache, 0)
                 return nil
             }
             inputTextureCbCr = CVMetalTextureGetTexture(cvTexCbCr)
        
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: // Apple Log 10-bit 4:2:2 YpCbCr ('x422') - Bi-Planar
             logger.trace("Processing YUV ('x422' Bi-Planar) frame.")
             requiresYUVProcessing = true
             pipelineState = computePipelineStateYUV

             // Texture for Y plane (Plane 0) - Use r16Unorm for 10/12/16-bit Y data
             var cvTextureY_x422: CVMetalTexture?
             var status_x422 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .r16Unorm, width, height, 0, &cvTextureY_x422)
             guard status_x422 == kCVReturnSuccess, let cvTexY_x422 = cvTextureY_x422 else {
                 logger.error("Failed to create input Y Metal texture (r16Unorm) for x422: \(status_x422)")
                 CVMetalTextureCacheFlush(cache, 0)
                 return nil
             }
             inputTextureY = CVMetalTextureGetTexture(cvTexY_x422)

             // Texture for CbCr plane (Plane 1) - Use rg16Unorm for 10/12/16-bit UV data
             var cvTextureCbCr_x422: CVMetalTexture?
             // Note: Width for CbCr plane is half the Luma width in 4:2:2
             status_x422 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .rg16Unorm, width / 2, height, 1, &cvTextureCbCr_x422)
             guard status_x422 == kCVReturnSuccess, let cvTexCbCr_x422 = cvTextureCbCr_x422 else {
                 logger.error("Failed to create input CbCr Metal texture (rg16Unorm) for x422: \(status_x422)")
                 CVMetalTextureCacheFlush(cache, 0)
                 return nil
             }
             inputTextureCbCr = CVMetalTextureGetTexture(cvTexCbCr_x422)

        default:
            logger.error("Unsupported pixel format for Metal processing: \(pixelFormat)")
            return nil // Cannot process this format
        }

        guard let selectedPipelineState = pipelineState,
              let currentLUTTexture = lutTexture, // Ensure a LUT is set for processing
              let firstInputTexture = inputTextureY else { // Y texture is always needed
             logger.error("Metal processor prerequisites failed: PipelineState=\(pipelineState != nil), LUT=\(self.lutTexture != nil), InputY=\(inputTextureY != nil)")
             CVMetalTextureCacheFlush(cache, 0)
             return nil
         }
        
         if requiresYUVProcessing && inputTextureCbCr == nil {
             logger.error("Metal processor YUV prerequisites failed: CbCr texture is nil.")
             CVMetalTextureCacheFlush(cache, 0)
             return nil
         }

        // --- Prepare Output Texture (Always BGRA) ---
        var outputPixelBuffer: CVPixelBuffer?
        // Ensure Metal compatibility for the output buffer
        let outputAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], // Enable IOSurface backing
            kCVPixelBufferMetalCompatibilityKey as String: true // Explicitly request Metal compatibility
        ]

        var status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, outputAttributes as CFDictionary, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outPixelBuffer = outputPixelBuffer else {
             logger.error("Failed to create output BGRA pixel buffer: \(status)")
             CVMetalTextureCacheFlush(cache, 0)
             return nil
        }

        var cvTextureOut: CVMetalTexture?
        // Create texture view for the output buffer
        status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, outPixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTextureOut)
        guard status == kCVReturnSuccess, let cvTexOut = cvTextureOut, let outputTexture = CVMetalTextureGetTexture(cvTexOut) else {
            logger.error("Failed to create output Metal texture (BGRA): \(status)")
            CVMetalTextureCacheFlush(cache, 0)
            return nil
        }

        // --- Execute Compute Kernel ---
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder() else {
            logger.error("Failed to create Metal command buffer or encoder.")
            CVMetalTextureCacheFlush(cache, 0)
            return nil
        }

        computeCommandEncoder.setComputePipelineState(selectedPipelineState)

        // Set textures based on processing type
        if requiresYUVProcessing {
            computeCommandEncoder.setTexture(firstInputTexture, index: 0) // Y Plane
            computeCommandEncoder.setTexture(inputTextureCbCr!, index: 1) // CbCr Plane
            computeCommandEncoder.setTexture(outputTexture, index: 2)    // Output BGRA
            computeCommandEncoder.setTexture(currentLUTTexture, index: 3) // LUT
        } else {
            computeCommandEncoder.setTexture(firstInputTexture, index: 0) // Input BGRA
            computeCommandEncoder.setTexture(outputTexture, index: 1)    // Output BGRA
            computeCommandEncoder.setTexture(currentLUTTexture, index: 2) // LUT
        }


        // Configure threadgroups (remains the same)
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1) // Common good size
        let threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        computeCommandEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeCommandEncoder.endEncoding()

        // Commit and wait for completion
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted() // Wait synchronously for simplicity in recording pipeline

        // Check for errors after execution
        if let error = commandBuffer.error {
            logger.error("Metal command buffer execution failed: \(error.localizedDescription)")
             CVMetalTextureCacheFlush(cache, 0) // Flush cache on error too
            return nil
        }

        // Flush the cache before returning the processed buffer
        CVMetalTextureCacheFlush(cache, 0)

        logger.trace("Successfully processed frame using Metal compute kernel (\(requiresYUVProcessing ? "YUV" : "RGB")).")
        return outPixelBuffer // Return the BGRA output buffer
    }
} 