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

// Fragment shader for Apple Log YUV (specifically 'x422' BiPlanar format)
fragment float4 fragmentShaderYUV(RasterizerData in [[stage_in]],
                                texture2d<float, access::sample> yTexture [[texture(0)]],      // Luma (Y) plane (r16unorm)
                                texture2d<float, access::sample> cbcrTexture [[texture(1)]],   // Chroma (CbCr) plane (rg16unorm)
                                texture3d<float> lutTexture [[texture(2)]]) {   // LUT

    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    // Sample Luma (Y) and Chroma (CbCr)
    float y = yTexture.sample(textureSampler, in.textureCoordinate).r;
    float2 cbcr = cbcrTexture.sample(textureSampler, in.textureCoordinate).rg;
    
    // Apple's x422 format uses BT.2020 color space with full range encoding
    float Y = y;
    float Cb = cbcr.r - 0.5;  // Center around zero
    float Cr = cbcr.g - 0.5;  // Center around zero
    
    // Direct conversion from YUV to RGB using BT.2020 coefficients
    // Manually expanded form of the matrix multiplication
    float R = Y + 1.4746 * Cr;
    float G = Y - 0.1646 * Cb - 0.5714 * Cr;
    float B = Y + 1.8814 * Cb;
    
    // Ensure valid RGB values
    float3 rgb = clamp(float3(R, G, B), 0.0, 1.0);
    
    // Sample the LUT with the RGB values
    float4 lutColor = lutTexture.sample(lutSampler, rgb);
    
    return float4(lutColor.rgb, 1.0);
} 