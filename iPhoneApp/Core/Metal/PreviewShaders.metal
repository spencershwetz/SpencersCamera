#include <metal_stdlib>
using namespace metal;

// Vertex shader outputs and fragment shader inputs
struct RasterizerData {
    float4 position [[position]];
    float2 textureCoordinate;
};

// Vertex shader
vertex RasterizerData vertexShader(uint vertexID [[vertex_id]]) {
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
                                constant bool &isLUTActive [[buffer(0)]]) {                    // Uniform to check if LUT is active

    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    // Sample Luma (Y) and Chroma (CbCr)
    float y = yTexture.sample(textureSampler, in.textureCoordinate).r;
    float2 cbcr = cbcrTexture.sample(textureSampler, in.textureCoordinate).rg;
    
    // YUV to RGB (BT.2020) -> Results are Log encoded RGB
    float Y = y;
    float Cb = cbcr.r - 0.5;
    float Cr = cbcr.g - 0.5;
    float R = Y + 1.4746 * Cr;
    float G = Y - 0.1646 * Cb - 0.5714 * Cr;
    float B = Y + 1.8814 * Cb;
    
    // Ensure valid RGB values (Log encoded)
    float3 log_rgb = clamp(float3(R, G, B), 0.0, 1.0);
    
    if (isLUTActive) {
        // --- APPLY LUT DIRECTLY TO LOG SIGNAL ---
        float4 lutColor = lutTexture.sample(lutSampler, log_rgb); // Use log_rgb for lookup
        // Return the color from the LUT
        return float4(lutColor.rgb, 1.0);
        
        // --- DEBUG OUTPUT: Return RED if LUT is active ---
        // return float4(1.0, 0.0, 0.0, 1.0); // Red
    } else {
        // --- RETURN RAW LOG SIGNAL ---
        // MTKView's pixel format (likely sRGB) will handle display transformation.
        return float4(log_rgb, 1.0);
        
        // --- DEBUG OUTPUT: Return GREEN if LUT is NOT active ---
        // return float4(0.0, 1.0, 0.0, 1.0); // Green
    }
} 