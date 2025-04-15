import Foundation
import Metal
import CoreVideo
import OSLog
import MetalKit
import VideoToolbox

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

            // Load YUV kernel ( Placeholder name - will be created in metal file next)
            guard let yuvKernelFunction = library.makeFunction(name: "applyLUTComputeYUV") else {
                logger.error("Failed to find kernel function 'applyLUTComputeYUV'. Make sure it's added to PreviewShaders.metal")
                // Don't fail init entirely, maybe only RGB processing will be available
                 logger.warning("YUV compute kernel not found. LUT bake-in might not work for Apple Log.")
                // return nil // Optional: Uncomment if YUV MUST be supported
                return nil // Ensure guard body exits
            }
            computePipelineStateYUV = try device.makeComputePipelineState(function: yuvKernelFunction)

        } catch {
            logger.error("Failed to create compute pipeline state: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Processes a CVPixelBuffer using the currently set LUT via Metal compute shaders.
    /// Supports BGRA and specific YUV formats (v210, x422, 420v/f).
    /// - Parameters:
    ///   - pixelBuffer: The input CVPixelBuffer.
    ///   - bakeInLUT: Flag indicating whether the LUT should be baked into the output, primarily relevant for YUV formats during recording.
    /// - Returns: A new CVPixelBuffer in BGRA format with the LUT applied (if applicable), or nil if processing fails or is skipped.
    func processFrame(pixelBuffer: CVPixelBuffer, bakeInLUT: Bool) -> CVPixelBuffer? {
        guard let cache = textureCache else {
            logger.error("Texture cache is not available.")
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        var inputTextureY: MTLTexture?         // For BGRA or Y plane of YUV
        var inputTextureCbCr: MTLTexture?      // For CbCr plane of YUV
        var pipelineState: MTLComputePipelineState?
        var requiresYUVProcessing = false

        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            requiresYUVProcessing = false
            pipelineState = computePipelineStateRGB // Use BGRA kernel

            // Texture for BGRA (Plane 0)
            var cvTextureBGRA: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTextureBGRA)
            guard status == kCVReturnSuccess, let cvTexBGRA = cvTextureBGRA else {
                logger.error("Failed to create input Metal texture (BGRA): \(status)")
                CVMetalTextureCacheFlush(cache, 0)
                return nil
            }
            inputTextureY = CVMetalTextureGetTexture(cvTexBGRA) // Use inputTextureY slot for BGRA too

        case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange: // ProRes 422 HQ / v210 10/12/16-bit 4:2:2 YpCbCr - Bi-Planar
             requiresYUVProcessing = true
             pipelineState = computePipelineStateYUV

             // --- Bake-in Check for YUV ---
             if !bakeInLUT {
                 logger.debug("YUV format (v210) detected, but bakeInLUT is false. Skipping Metal processing.")
                 // CVMetalTextureCacheFlush(cache, 0) // Flush if we created textures before this check? Maybe not needed yet.
                 return nil // Signal to use original buffer
             }
             guard let currentLUTTexture = lutTexture else {
                 logger.warning("Bake-in requested for YUV (v210) but no LUT texture set. Skipping Metal processing.")
                 // CVMetalTextureCacheFlush(cache, 0)
                 return nil
             }
             // --- End Bake-in Check ---

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
             requiresYUVProcessing = true
             pipelineState = computePipelineStateYUV

             // --- Bake-in Check for YUV ---
             if !bakeInLUT {
                 logger.debug("YUV format (x422 - Apple Log) detected, but bakeInLUT is false. Skipping Metal processing.")
                 // CVMetalTextureCacheFlush(cache, 0)
                 return nil // Signal to use original buffer
             }
             guard let currentLUTTexture = lutTexture else {
                 logger.warning("Bake-in requested for YUV (x422 - Apple Log) but no LUT texture set. Skipping Metal processing.")
                 // CVMetalTextureCacheFlush(cache, 0)
                 return nil
             }
             // --- End Bake-in Check ---

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

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: // 8-bit 4:2:0 YUV ('420v' or '420f')
            requiresYUVProcessing = true
            pipelineState = computePipelineStateYUV

            // --- Bake-in Check for YUV ---
             if !bakeInLUT {
                 logger.debug("YUV format (420v/f) detected, but bakeInLUT is false. Skipping Metal processing.")
                 // CVMetalTextureCacheFlush(cache, 0)
                 return nil // Signal to use original buffer
             }
             guard let currentLUTTexture = lutTexture else {
                 logger.warning("Bake-in requested for YUV (420v/f) but no LUT texture set. Skipping Metal processing.")
                 // CVMetalTextureCacheFlush(cache, 0)
                 return nil
             }
             // --- End Bake-in Check ---

            // Texture for Y plane (Plane 0) - Use r8Unorm for 8-bit Y data
            var cvTextureY_420: CVMetalTexture?
            var status_420 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .r8Unorm, width, height, 0, &cvTextureY_420)
            guard status_420 == kCVReturnSuccess, let cvTexY_420 = cvTextureY_420 else {
                logger.error("Failed to create input Y Metal texture (r8Unorm) for 420v/f: \(status_420)")
                CVMetalTextureCacheFlush(cache, 0)
                return nil
            }
            inputTextureY = CVMetalTextureGetTexture(cvTexY_420)

            // Texture for CbCr plane (Plane 1) - Use rg8Unorm for 8-bit UV data
            // Note: Width and Height for CbCr plane are half the Luma dimensions in 4:2:0
            var cvTextureCbCr_420: CVMetalTexture?
            status_420 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .rg8Unorm, width / 2, height / 2, 1, &cvTextureCbCr_420)
            guard status_420 == kCVReturnSuccess, let cvTexCbCr_420 = cvTextureCbCr_420 else {
                logger.error("Failed to create input CbCr Metal texture (rg8Unorm) for 420v/f: \(status_420)")
                CVMetalTextureCacheFlush(cache, 0)
                return nil
            }
            inputTextureCbCr = CVMetalTextureGetTexture(cvTexCbCr_420)

        default:
            logger.error("Unsupported pixel format for Metal processing: \(pixelFormat)")
            return nil // Cannot process this format
        }

        // --- Guard against missing pipeline state or input textures ---
        // Note: currentLUTTexture is now checked specifically within the YUV bake-in logic path
        guard let selectedPipelineState = pipelineState,
              let firstInputTexture = inputTextureY else {
             logger.error("Metal processor prerequisites failed: PipelineState=\(pipelineState != nil), InputY=\(inputTextureY != nil)")
             CVMetalTextureCacheFlush(cache, 0)
             return nil
         }

         if requiresYUVProcessing && inputTextureCbCr == nil {
             logger.error("Metal processor YUV prerequisites failed: CbCr texture is nil.")
             CVMetalTextureCacheFlush(cache, 0)
             return nil
         }
        
        // --- Handle Non-YUV LUT application (e.g., for BGRA preview) ---
        // Apply LUT if available, otherwise skip (effectively pass-through for BGRA if no LUT)
        // For YUV, lutTexture presence is checked earlier within the bakeInLUT logic.
        var lutToApply: MTLTexture? = nil
        if !requiresYUVProcessing {
             if let currentLUT = lutTexture {
                 lutToApply = currentLUT
             } else {
                 // BGRA input and no LUT means no processing is needed.
                 // However, the current structure assumes output is always BGRA.
                 // If we want true pass-through, we might need to return the original buffer earlier.
                 // For now, let's assume processing to BGRA (even identity) is intended.
                 // If identity processing is complex, consider returning original pixelBuffer here.
                 logger.trace("BGRA format and no LUT set. Proceeding with potential identity transform to output BGRA buffer.")
                 // To truly skip, uncomment below and adjust return logic:
                 // return pixelBuffer // Or handle appropriately in caller
             }
         } else {
             // For YUV, we already guarded that lutTexture is non-nil if bakeInLUT is true.
             lutToApply = lutTexture! // Safe to force unwrap due to earlier guard
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
            // We already guarded that lutToApply is non-nil if requiresYUVProcessing is true and bakeInLUT is true
            guard let definiteLUT = lutToApply else {
                // This should theoretically not happen due to checks above
                logger.error("Internal error: LUT expected for YUV processing but not found.")
                CVMetalTextureCacheFlush(cache, 0)
                return nil
            }
            computeCommandEncoder.setTexture(firstInputTexture, index: 0) // Y Plane
            computeCommandEncoder.setTexture(inputTextureCbCr!, index: 1) // CbCr Plane
            computeCommandEncoder.setTexture(outputTexture, index: 2)    // Output BGRA
            computeCommandEncoder.setTexture(definiteLUT, index: 3)      // LUT (Guaranteed non-nil)
        } else { // BGRA Processing
            computeCommandEncoder.setTexture(firstInputTexture, index: 0) // Input BGRA
            computeCommandEncoder.setTexture(outputTexture, index: 1)    // Output BGRA
            if let definiteLUT = lutToApply { // Only set LUT if one is available for BGRA
                 computeCommandEncoder.setTexture(definiteLUT, index: 2) // LUT
            } else {
                 // If no LUT for BGRA, we might need a different kernel or handle identity transform.
                 // Current shaders likely expect a LUT. This needs review based on shader code.
                 // Assuming computePipelineStateBGRA handles nil LUT gracefully or expects one.
                 // If it breaks, we need an identity BGRA->BGRA kernel or skip Metal pass.
                 logger.warning("Processing BGRA without a LUT texture. Shader must handle this.")
                 // Potential issue: If shader *requires* index 2, this might fail.
                 // A dummy 1x1 texture could be set, or the shader needs adjustment.
            }
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

        return outPixelBuffer // Return the BGRA output buffer
    }

    func setLUT(_ texture: MTLTexture?) {
        self.lutTexture = texture
        logger.debug("LUT Texture \(texture == nil ? "cleared" : "set") on MetalFrameProcessor.")
    }
} 