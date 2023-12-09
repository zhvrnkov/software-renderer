//
//  Shaders.metal
//  renderer
//
//  Created by Vlad on 09.12.2023.
//

#include <metal_stdlib>
using namespace metal;

kernel void render_triangle(
                            texture2d<float, access::write> color_buf,
                            constant uint2& offset,
                            constant array<simd_uint2, 3>& vertices,
                            constant array<simd_float3, 3>& colors,
                            constant float2x2& baricentricM,
                            uint2 tpg [[ thread_position_in_grid ]]
                            ) 
{
    float2 xy = float2(offset + tpg) + 0.5;
    float2 cf = float2(vertices[2]) + 0.5;
    float2 wab = baricentricM * (xy - cf);
    float3 ws = float3(wab.x, wab.y, 1 - wab.x - wab.y);

    auto t = 0 <= ws && ws <= 1;
    bool inside = all(t);
    
    float3 color = ws[0] * colors[0] + ws[1] * colors[1] + ws[2] * colors[2];
    
    if (inside) {
        color_buf.write(float4(color, 1), offset + tpg);
    }
}
