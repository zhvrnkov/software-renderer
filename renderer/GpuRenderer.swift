//
//  GpuRenderer.swift
//  renderer
//
//  Created by Vlad on 09.12.2023.
//

import Foundation
import Metal
import simd

final class GpuRenderer {
    
    let context = MTLContext.shared
    lazy var renderTriangleComputePipelineState = try! context.makeComputePipelineState(
        functionName: "render_triangle"
    )
    
    func render(renderPass: RenderPass) {
        let indicesPerPrimitive = renderPass.primitiveType.verticesCount
        let texture = renderPass.colorBuffer.texture!
        context.scheduleAndWait { commandBuffer in
            commandBuffer.clear(texture: texture, color: .init())
            let primitivesCount = renderPass.indices.count / indicesPerPrimitive
            for primitiveIndex in 0..<primitivesCount {
                let base = primitiveIndex * indicesPerPrimitive
                let indices = renderPass.indices[base..<(base + indicesPerPrimitive)]
                let vertices = indices.map {
                    renderPass.vertices[$0].apply(transform: renderPass.transform)
                }
                
                let a = vertices[0].convertedToScreen(width: renderPass.colorBuffer.width, height: renderPass.colorBuffer.height)
                let b = vertices[1].convertedToScreen(width: renderPass.colorBuffer.width, height: renderPass.colorBuffer.height)
                let c = vertices[2].convertedToScreen(width: renderPass.colorBuffer.width, height: renderPass.colorBuffer.height)
                var baricentricM: matrix_float2x2 = {
                    let af = vector_float2(a.xyz.xy) + 0.5
                    let bf = vector_float2(b.xyz.xy) + 0.5
                    let cf = vector_float2(c.xyz.xy) + 0.5
                    return matrix_float2x2(columns: ((af - cf), (bf - cf))).inverse
                }()
                let sorted = [a, b, c].sorted { $0.xyz.y < $1.xyz.y }.map { simd_uint2($0.xyz.xy) }
                let xSorted = [a, b, c].sorted { $0.xyz.x < $1.xyz.x }.map { simd_uint2($0.xyz.xy) }
//                var leftVertices = [sorted[0], sorted[1], sorted[2]]
//                var rightVertices = [sorted[0], sorted[2]]
                
                let minY = sorted.first!.y
                let maxY = sorted.last!.y
                let minX = xSorted.first!.x
                let maxX = xSorted.last!.x
                let height = maxY - minY + 1
                let width = maxX - minX + 1
                
                var offset = simd_uint2(minX, minY)
                let cverts = [a, b, c]
                var vs = cverts.map { simd_uint2($0.xyz.xy) }
                var colors = cverts.map { $0.color }
                guard width != 0, height != 0 else {
                    continue
                }
                commandBuffer.compute { encoder in
                    encoder.set(value: &offset, index: 0)
                    encoder.setBytes(&vs, length: MemoryLayout.stride(ofValue: vs[0]) * vs.count, index: 1)
                    encoder.setBytes(&colors, length: MemoryLayout.stride(ofValue: colors[0]) * colors.count, index: 2)
                    encoder.set(value: &baricentricM, index: 3)
                    encoder.setTexture(texture, index: 0)
                    encoder.dispatch2d(
                        state: renderTriangleComputePipelineState,
                        size: MTLSize(width: Int(width), height: Int(height), depth: texture.depth)
                    )
                }
            }
        }
    }
}
