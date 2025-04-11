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

// Fragment shader
fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                             texture2d<float> cameraTexture [[texture(0)]],
                             texture3d<float> lutTexture [[texture(1)]]) {
    
    // Sampler for camera texture (linear filtering)
    constexpr sampler cameraSampler(mag_filter::linear, min_filter::linear);
    
    // Sampler for LUT texture (linear filtering, clamp to edge)
    constexpr sampler lutSampler(coord::normalized, 
                               filter::linear, 
                               address::clamp_to_edge);

    // Sample the camera texture
    float4 originalColor = cameraTexture.sample(cameraSampler, in.textureCoordinate);

    // Use the original color's RGB as 3D coordinates to sample the LUT
    // We assume the LUT expects normalized coordinates [0.0, 1.0]
    float3 lutCoord = originalColor.rgb;

    // Sample the 3D LUT
    float4 lutColor = lutTexture.sample(lutSampler, lutCoord);
    
    // Return the color from the LUT, preserving original alpha
    return float4(lutColor.rgb, originalColor.a);
} 