#include <metal_stdlib>
using namespace metal;

// Placeholder vertex shader
vertex float4 vertexShader(uint vertexID [[vertex_id]])
{
    // Basic pass-through, will be replaced later
    float4x4 identity = float4x4(1.0);
    return identity * float4(0.0, 0.0, 0.0, 1.0);
}

// Placeholder fragment shader
fragment float4 fragmentShader()
{
    // Basic red color, will be replaced later
    return float4(1.0, 0.0, 0.0, 1.0);
} 