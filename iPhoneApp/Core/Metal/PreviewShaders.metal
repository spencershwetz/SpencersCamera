#include <metal_stdlib>
using namespace metal;

// Vertex shader outputs and fragment shader inputs
struct RasterizerData {
    float4 position [[position]];
    float2 textureCoordinate;
};

// Vertex shader with rotation
vertex RasterizerData vertexShaderWithRotation(uint vertexID [[vertex_id]],
                                             constant float &rotation [[buffer(1)]]) {
    const float4 vertices[] = {
        float4(-1.0, -1.0, 0.0, 1.0),
        float4( 1.0, -1.0, 0.0, 1.0),
        float4(-1.0,  1.0, 0.0, 1.0),
        float4( 1.0,  1.0, 0.0, 1.0)
    };
    
    const float2 texCoords[] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    
    // Create rotation matrix
    float cosR = cos(rotation);
    float sinR = sin(rotation);
    float2x2 rotationMatrix = float2x2(cosR, -sinR,
                                      sinR, cosR);
    
    // Get the vertex position and rotate it
    float4 position = vertices[vertexID];
    float2 rotatedPosition = rotationMatrix * position.xy;
    
    RasterizerData out;
    out.position = float4(rotatedPosition, 0.0, 1.0);
    out.textureCoordinate = texCoords[vertexID];
    
    return out;
}

// Vertex shader
vertex RasterizerData vertexShader(uint vertexID [[vertex_id]]) {
    const float4 vertices[] = {
        float4(-1.0, -1.0, 0.0, 1.0),
        float4( 1.0, -1.0, 0.0, 1.0),
        float4(-1.0,  1.0, 0.0, 1.0),
        float4( 1.0,  1.0, 0.0, 1.0)
    };
    
    // Fixed texture coordinates for proper orientation
    const float2 texCoords[] = {
        float2(0.0, 1.0), // Bottom left
        float2(1.0, 1.0), // Bottom right 
        float2(0.0, 0.0), // Top left
        float2(1.0, 0.0)  // Top right
    };
    
    RasterizerData out;
    out.position = vertices[vertexID];
    out.textureCoordinate = texCoords[vertexID];
    
    return out;
}

// Fragment shader for RGB/BGRA input
fragment float4 fragmentShaderRGB(RasterizerData in [[stage_in]],
                                texture2d<float> cameraTexture [[texture(0)]],
                                texture3d<float> lutTexture [[texture(1)]]) {
    
    constexpr sampler cameraSampler(mag_filter::linear, min_filter::linear);
    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    // Sample the camera texture (BGRA)
    float4 originalColor = cameraTexture.sample(cameraSampler, in.textureCoordinate);

    // Use the original color's RGB as 3D coordinates to sample the LUT
    float3 lutCoord = originalColor.rgb;

    // Sample the 3D LUT
    float4 lutColor = lutTexture.sample(lutSampler, lutCoord);
    
    // Return the color from the LUT, preserving original alpha
    return float4(lutColor.rgb, originalColor.a);
}

// --- REMOVE APPLE LOG TO LINEAR CONVERSION HELPERS ---
/*
// Constants for Apple Log to Linear conversion (from Apple Log Profile White Paper, Sept 2023)
constant float APPLE_LOG_R0 = -0.05641088;
constant float APPLE_LOG_Rt = 0.01;
constant float APPLE_LOG_c = 47.28711236;
constant float APPLE_LOG_beta = 0.00964052;
constant float APPLE_LOG_gamma = 0.08550479;
constant float APPLE_LOG_delta = 0.69336945;

// Calculate the threshold Pt = c * (Rt - R0)^2
constant float APPLE_LOG_Pt = APPLE_LOG_c * (APPLE_LOG_Rt - APPLE_LOG_R0) * (APPLE_LOG_Rt - APPLE_LOG_R0);

// Function to convert a single Apple Log encoded channel to linear
float appleLogToLinearValue(float P) { // P is the encoded pixel value [0,1]
    // Apply Apple Log inverse EOTF (Log -> Linear)
    if (P < 0.0) {
        return APPLE_LOG_R0; // Return R0 for values below 0
    } else if (P < APPLE_LOG_Pt) {
        // Parabolic/Square root segment: R = sqrt(P/c) + R0
        // Note: Ensure P/c is non-negative, though P should be >= 0 here.
        return sqrt(max(0.0, P / APPLE_LOG_c)) + APPLE_LOG_R0;
    } else {
        // Logarithmic segment: R = pow(2, (P - delta) / gamma) - beta
        return pow(2.0, (P - APPLE_LOG_delta) / APPLE_LOG_gamma) - APPLE_LOG_beta;
    }
}

// Function to convert Apple Log encoded RGB to linear RGB
float3 appleLogToLinear(float3 log_rgb) {
    return float3(appleLogToLinearValue(log_rgb.r),
                  appleLogToLinearValue(log_rgb.g),
                  appleLogToLinearValue(log_rgb.b));
}
*/
// --- END APPLE LOG HELPERS ---

// Fragment shader for Apple Log YUV (specifically 'x422' BiPlanar format)
fragment float4 fragmentShaderYUV(RasterizerData in [[stage_in]],
                                texture2d<float, access::sample> yTexture [[texture(0)]],      // Luma (Y) plane
                                texture2d<float, access::sample> cbcrTexture [[texture(1)]],   // Chroma (CbCr) plane
                                texture3d<float> lutTexture [[texture(2)]],                   // LUT
                                constant bool &isLUTActive [[buffer(0)]],                    // Uniform to check if LUT is active
                                constant bool &isBT709 [[buffer(1)]]) {                      // Uniform to check color space

    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    // Sample Luma (Y) and Chroma (CbCr)
    float y = yTexture.sample(textureSampler, in.textureCoordinate).r;
    float2 cbcr = cbcrTexture.sample(textureSampler, in.textureCoordinate).rg;
    
    // Convert to video range [16/255, 235/255] for Y and [16/255, 240/255] for CbCr
    float Y = y * (219.0/255.0) + (16.0/255.0);
    float Cb = cbcr.r - 0.5;
    float Cr = cbcr.g - 0.5;
    
    float3 rgb;
    if (isBT709) {
        // BT.709 coefficients for video range
        rgb = float3(
            Y + 1.5748 * Cr,
            Y - 0.1873 * Cb - 0.4681 * Cr,
            Y + 1.8556 * Cb
        );
    } else {
        // BT.2020 coefficients (existing code)
        rgb = float3(
            Y + 1.4746 * Cr,
            Y - 0.1646 * Cb - 0.5714 * Cr,
            Y + 1.8814 * Cb
        );
    }
    
    // Ensure valid RGB values
    float3 clampedRGB = clamp(rgb, 0.0, 1.0);
    
    if (isLUTActive) {
        float4 lutColor = lutTexture.sample(lutSampler, clampedRGB);
        return float4(lutColor.rgb, 1.0);
    } else {
        return float4(clampedRGB, 1.0);
    }
}

// --- Compute Kernels for LUT Bake-in ---

// Kernel function to apply a 3D LUT to an RGB texture
kernel void applyLUTComputeRGB(
    texture2d<float, access::read>  sourceTexture  [[texture(0)]], // Input video frame (BGRA)
    texture2d<float, access::write> outputTexture [[texture(1)]], // Output texture (BGRA)
    texture3d<float, access::sample> lutTexture    [[texture(2)]], // 3D LUT cube
    uint2                          gid            [[thread_position_in_grid]])
{
    // Ensure we don't write outside the texture bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    // Sampler for the LUT
    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    // Read the input color (assumes input texture is float4 BGRA or RGBA)
    // Swizzle if necessary based on input format (e.g., .bgra for BGRA)
    float4 inColor = sourceTexture.read(gid); // Read as is, assuming RGBA for simplicity, adjust if BGRA direct read needed

    // Perform the 3D LUT lookup using the input color's RGB components
    // Input color space is assumed to match the LUT's expected input space (e.g., sRGB or Linear)
    float3 lookupCoords = inColor.rgb;
    float4 outColor = lutTexture.sample(lutSampler, lookupCoords);

    // Write the result to the output texture
    // Preserve alpha if needed, or set to 1.0
    outputTexture.write(float4(outColor.rgb, inColor.a), gid);
}

// Kernel function to apply a 3D LUT to an Apple Log YUV ('x422') texture
kernel void applyLUTComputeYUV(
    texture2d<float, access::read>  yTexture      [[texture(0)]], // Input Luma plane (e.g., r16Unorm)
    texture2d<float, access::read>  cbcrTexture   [[texture(1)]], // Input Chroma plane (e.g., rg16Unorm)
    texture2d<float, access::write> outputTexture [[texture(2)]], // Output texture (BGRA8Unorm)
    texture3d<float, access::sample> lutTexture    [[texture(3)]], // 3D LUT cube
    uint2                          gid            [[thread_position_in_grid]])
{
    // Ensure we don't write outside the texture bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    // Sampler for the LUT
    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    // Sampler for Y/CbCr textures (can use gid directly for read if preferred)
    // constexpr sampler textureSampler(coord::pixel, filter::linear); // Use linear if interpolation needed, or point

    // Read Luma (Y) - texture coordinates are the same as gid for Y plane
    float y = yTexture.read(gid).r;

    // Read Chroma (CbCr) - texture coordinates need adjustment for 4:2:2 subsampling
    // Read from the pixel coordinate corresponding to the current Luma position.
    // Since CbCr width is half, the x coordinate is gid.x / 2.
    // For 4:2:0, CbCr height is also half, so y coordinate is gid.y / 2.
    // For 4:2:2, CbCr height matches Y, so y coordinate *should* be gid.y.
    // Using gid.y / 2 for now to fix the immediate 4:2:0 issue.
    // TODO: Pass format flag to shader for perfect 4:2:2 vs 4:2:0 handling.
    uint2 cbcr_gid = uint2(gid.x / 2, gid.y / 2);
    float2 cbcr = cbcrTexture.read(cbcr_gid).rg;

    // Convert YUV (BT.2020 Log) to RGB (Log)
    // Values are assumed to be normalized [0, 1] from the textures (r16Unorm, rg16Unorm)
    float Y = y;
    float Cb = cbcr.r - 0.5; // Offset Cb
    float Cr = cbcr.g - 0.5; // Offset Cr

    // BT.2020 YUV to RGB conversion matrix (for full range YCbCr)
    float R = Y + 1.4746 * Cr;
    float G = Y - 0.16455 * Cb - 0.57135 * Cr;
    float B = Y + 1.8814 * Cb;

    // Clamp the Log RGB result to valid [0, 1] range for LUT lookup
    float3 log_rgb = clamp(float3(R, G, B), 0.0, 1.0);

    // Perform the 3D LUT lookup using the log-encoded RGB components
    float3 lookupCoords = log_rgb;
    float4 outLutColor = lutTexture.sample(lutSampler, lookupCoords);

    // Write the final color (from LUT) to the output BGRA texture
    // The LUT output is assumed to be in the target color space (e.g., sRGB for display/standard video)
    outputTexture.write(float4(outLutColor.rgb, 1.0), gid);
} 