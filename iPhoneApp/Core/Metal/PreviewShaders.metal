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

// Fragment shader for YUV (specifically kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
fragment float4 fragmentShaderYUV(RasterizerData in [[stage_in]],
                                texture2d<float, access::sample> yTexture [[texture(0)]],      // Luma plane (r16unorm)
                                texture2d<float, access::sample> cbcrTexture [[texture(1)]], // Chroma plane (rg16unorm)
                                texture3d<float> lutTexture [[texture(2)]]) {   // LUT

    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    // Sample Luma (Y) and Chroma (CbCr)
    float y = yTexture.sample(textureSampler, in.textureCoordinate).r;
    // Chroma texture uses the same texture coordinates, Metal handles interpolation
    float2 cbcr = cbcrTexture.sample(textureSampler, in.textureCoordinate).rg;

    // YCbCr to RGB conversion matrix for Rec.2020 (Video Range)
    // Assumes Y is in [16/255, 235/255] and Cb/Cr are in [16/255, 240/255] shifted to center around 0.5 for unorm textures
    // Adjust Y, Cb, Cr ranges from unorm [0, 1] back to their nominal video ranges centered around 0 or 0.5
    float Y = y;                      // Already [0, 1] -> maps to Y' [0, 1]
    float Cb = cbcr.x - 0.5;          // Map [0, 1] -> [-0.5, 0.5] (Use .x for Cb)
    float Cr = cbcr.y - 0.5;          // Map [0, 1] -> [-0.5, 0.5] (Use .y for Cr)
    
    // Rec.2020 Color Conversion Constants (approximations)
    const float3x3 yuvToRgbMatrix = float3x3(\
        float3(1.0,  0.0,      1.4746),    // R = Y + 1.4746 * Cr
        float3(1.0, -0.16455, -0.57135), // G = Y - 0.16455 * Cb - 0.57135 * Cr
        float3(1.0,  1.8814,   0.0)      // B = Y + 1.8814 * Cb
    );

    // Perform conversion
    float3 rgb = yuvToRgbMatrix * float3(Y, Cb, Cr);

    // IMPORTANT: The rgb values here represent the Apple Log signal encoded in Rec.2020.
    // Since the LUT expects Apple Log input directly, use these RGB values.
    float3 lutCoord = clamp(rgb, 0.0, 1.0); // Clamp to valid texture coordinates

    // Sample the 3D LUT
    float4 lutColor = lutTexture.sample(lutSampler, lutCoord);

    // Return the color from the LUT, with alpha = 1.0
    return float4(lutColor.rgb, 1.0);
} 