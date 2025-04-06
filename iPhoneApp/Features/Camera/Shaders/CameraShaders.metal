#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;
    
    // Simple pass-through vertex shader for a full-screen quad
    float4 positions[4] = {
        float4(-1.0, -1.0, 0.0, 1.0), // Bottom-left
        float4( 1.0, -1.0, 0.0, 1.0), // Bottom-right
        float4(-1.0,  1.0, 0.0, 1.0), // Top-left
        float4( 1.0,  1.0, 0.0, 1.0)  // Top-right
    };
    
    float2 texCoords[4] = {
        float2(0.0, 1.0), // Bottom-left tex coord
        float2(1.0, 1.0), // Bottom-right tex coord
        float2(0.0, 0.0), // Top-left tex coord
        float2(1.0, 0.0)  // Top-right tex coord
    };

    out.position = positions[vertexID];
    out.texCoord = texCoords[vertexID];
    
    return out;
}

fragment float4 samplingShader(VertexOut in [[stage_in]],
                               texture2d<float> texture [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return texture.sample(s, in.texCoord);
} 