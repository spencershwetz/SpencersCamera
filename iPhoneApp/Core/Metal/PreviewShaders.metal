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
                             texture2d<float> cameraTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = cameraTexture.sample(textureSampler, in.textureCoordinate);
    return color;
} 