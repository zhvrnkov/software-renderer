//
//  Shaders.metal
//  renderer
//
//  Created by Vlad on 09.12.2023.
//

#include <metal_stdlib>
#include <metal_matrix>
#include <metal_common>
using namespace metal;

#include <simd/simd.h>

float2x2 inverseMatrix(float2x2 matrix) {
    float determinant = metal::determinant(matrix);
    
    // Check if the determinant is non-zero
    if (determinant != 0.0) {
        float2x2 adj;
        adj.columns[0][0] = matrix.columns[1][1];
        adj.columns[0][1] = -matrix.columns[0][1];
        adj.columns[1][0] = -matrix.columns[1][0];
        adj.columns[1][1] = matrix.columns[0][0];
        
        return adj / determinant;
    }
    
    // If the determinant is zero, return the original matrix
    return matrix;
}

kernel void clear_depth_buffer(texture2d<float, access::write> depth,
                               uint2 tpg [[ thread_position_in_grid ]])
{
    depth.write(float(INFINITY), tpg);
}

struct VertexOut {
    float4 pos;
    float3 color;
};

VertexOut vertex_shader(
                        simd_float3 xyz,
                        simd_float3 color,
                        constant float4x4& transform
                        )
{
    float4 xyzw = transform * float4(xyz, 1);
    VertexOut out;
    out.pos = xyzw;
    out.color = color;
    return out;
}

kernel void vertex_pass(
                        constant simd_float3 *vertices,
                        constant simd_float3 *colors,
                        constant float4x4& transform,
                        constant long2& screen_size,
                        device VertexOut *output,
                        uint index [[ thread_position_in_grid ]]
                        )
{
    VertexOut vout = vertex_shader(vertices[index], colors[index], transform);
    
    vout.pos.xyz /= vout.pos.w;
    // convert to pixels
    float2 uv = vout.pos.xy * float2(0.5, -0.5) + 0.5;
    float2 pixels = round(uv * float2(screen_size));
    vout.pos.xy = pixels;

    output[index] = vout;
}

//METAL_FUNC
//uint min3(uint a, uint b, uint c)
//{
//    return min(min(a, b), c);
//}
//
//METAL_FUNC
//uint max3(uint a, uint b, uint c)
//{
//    return max(max(a, b), c);
//}

kernel void roi_pass(
                     constant VertexOut* vs,
                     constant long* indices,
                     texture2d<float, access::write> color_buf,
                     texture2d<float, access::read_write> z_buf,
                     uint primitive_index [[ thread_position_in_grid ]]
                     )
{
    long base_indices_index = primitive_index * 3;
    long3 ti = long3(
                     indices[base_indices_index],
                     indices[base_indices_index + 1],
                     indices[base_indices_index + 2]
                     );
    uint2 a = uint2(vs[ti[0]].pos.xy);
    uint2 b = uint2(vs[ti[1]].pos.xy);
    uint2 c = uint2(vs[ti[2]].pos.xy);

    uint minY = min3(a.y, b.y, c.y);
    uint maxY = max3(a.y, b.y, c.y);
    uint minX = min3(a.x, b.x, c.x);
    uint maxX = max3(a.x, b.x, c.x);
    uint height = maxY - minY + 1;
    uint width = maxX - minX + 1;
    
    for (uint y = minY; y <= maxY; y++) {
        for (uint x = minX; x <= maxX; x++) {
            float2 xy = float2(x, y) + 0.5;
            float3 ws;
            {
                float2 wab;
                float2 p1 = vs[ti.x].pos.xy;
                float2 p2 = vs[ti.y].pos.xy;
                float2 p3 = vs[ti.z].pos.xy;

                float divider = (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
                wab[0] = (p2.y - p3.y) * (xy.x - p3.x) + (p3.x - p2.x) * (xy.y - p3.y);
                wab[0] /= divider;

                wab[1] = (p3.y - p1.y) * (xy.x - p3.x) + (p1.x - p3.x) * (xy.y - p3.y);
                wab[1] /= divider;
                ws = float3(wab.x, wab.y, 1 - wab.x - wab.y);
            }
            bool inside = all(0 <= ws && ws <= 1);
            if (inside) {
                uint2 pos = uint2(x, y);
                VertexOut vin;
                vin.pos = ws[0] * vs[ti[0]].pos + ws[1] * vs[ti[1]].pos + ws[2] * vs[ti[2]].pos;
                float z_val = z_buf.read(pos).x;
                float curr_z_val = vin.pos.z;
                threadgroup_barrier(mem_flags::mem_threadgroup);

                if (curr_z_val < z_val) {
                    vin.color = ws[0] * vs[ti[0]].color + ws[1] * vs[ti[1]].color + ws[2] * vs[ti[2]].color;
                    color_buf.write(float4(vin.color, 1), pos);
                    z_buf.write(float4(curr_z_val), pos);
                }
            }
        }
    }
}

kernel void
reduce(const device int *input [[buffer(0)]],
       device int *output [[buffer(1)]],
       threadgroup int *ldata [[threadgroup(0)]],
       uint gid [[thread_position_in_grid]],
       uint lid [[thread_position_in_threadgroup]],
       uint lsize [[threads_per_threadgroup]],
       uint tsize [[threadgroups_per_grid]],
       uint simd_size [[threads_per_simdgroup]],
       uint simd_lane_id [[thread_index_in_simdgroup]],
       uint simd_group_id [[simdgroup_index_in_threadgroup]])
{
    uint block_w = 8096 / 32;
    uint blocks_count = lsize;
    uint block_index = lid;

    uint start_index = block_index * block_w;

    ldata[block_index] = 0;
    for (uint i = 0; i < block_w; i++) {
        ldata[block_index] += input[start_index + i];
    }
//    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (block_index == 0) {
        for (int i = 0; i < 32; i++) {
            *output += ldata[i];
        }
    }
}

float4 fragment_shader(
                       VertexOut vin
                       )
{
    return float4(vin.color, 1);
}

kernel void rasterizer_pass(
                            texture2d<float, access::write> color_buf,
                            texture2d<float, access::read_write> z_buf,
                            constant uint2& offset,
                            constant VertexOut* vs,
                            constant long* indices,
                            constant long& primitive_index,
                            uint2 tpg [[ thread_position_in_grid ]]
                            ) 
{
    float2 xy = float2(offset + tpg) + 0.5;
    long base_indices_index = primitive_index * 3;
    long3 ti = long3(indices[base_indices_index], indices[base_indices_index + 1], indices[base_indices_index + 2]);
    float3 ws;
    {
        float2 wab;
        float2 p1 = vs[ti.x].pos.xy;
        float2 p2 = vs[ti.y].pos.xy;
        float2 p3 = vs[ti.z].pos.xy;
        
        float divider = (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
        wab[0] = (p2.y - p3.y) * (xy.x - p3.x) + (p3.x - p2.x) * (xy.y - p3.y);
        wab[0] /= divider;
        
        wab[1] = (p3.y - p1.y) * (xy.x - p3.x) + (p1.x - p3.x) * (xy.y - p3.y);
        wab[1] /= divider;
        ws = float3(wab.x, wab.y, 1 - wab.x - wab.y);
    }
    

    bool inside = all(0 <= ws && ws <= 1);
    
    if (inside) {
        VertexOut vin;
        vin.pos = ws[0] * vs[ti[0]].pos + ws[1] * vs[ti[1]].pos + ws[2] * vs[ti[2]].pos;
        float z_val = z_buf.read(offset + tpg).x;
        float curr_z_val = vin.pos.z;
        
        if (curr_z_val < z_val) {
            vin.color = ws[0] * vs[ti[0]].color + ws[1] * vs[ti[1]].color + ws[2] * vs[ti[2]].color;
            color_buf.write(fragment_shader(vin), offset + tpg);
            z_buf.write(float4(curr_z_val), offset + tpg);
        }
    }
}
