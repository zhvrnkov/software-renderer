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
    
    struct VO {
        let pos: simd_float4
        let col: simd_float3
    }

    let context = MTLContext.shared
    lazy var clearDepthComputePipelineState = try! context.makeComputePipelineState(
        functionName: "clear_depth_buffer"
    )
    lazy var vertexPassComputePipelineState = try! context.makeComputePipelineState(
        functionName: "vertex_pass"
    )
    lazy var rasterizerPassComputePipelineState = try! context.makeComputePipelineState(
        functionName: "rasterizer_pass"
    )
    var vertexOutBuffer: MTLBuffer?
    
    func render(renderPass: RenderPass) {
        
        let texture = renderPass.colorBuffer.texture!
        let depthTexture = renderPass.depthBuffer.texture!
        let vertices = renderPass.vertices
        
        let length = vertices.count * MemoryLayout<VO>.stride
        let voBuffer: MTLBuffer = {
            if let vertexOutBuffer,
               vertexOutBuffer.length == length {
                return vertexOutBuffer
            } else {
                let newBuffer = context.device.makeBuffer(
                    length: length, options: .storageModeShared
                )!
                self.vertexOutBuffer = newBuffer
                return newBuffer
            }
        }()
        
        context.scheduleAndWait { commandBuffer in
            commandBuffer.compute { encoder in
                encoder.setTexture(depthTexture, index: 0)
                encoder.dispatch2d(state: clearDepthComputePipelineState, size: depthTexture.size)
            }
            commandBuffer.clear(texture: texture, color: .init())
            encodeVertexPass(commandBuffer: commandBuffer, renderPass: renderPass, outputBuffer: voBuffer)
        }
        context.scheduleAndWait { commandBuffer in
            encodeRasterizerPass(commandBuffer: commandBuffer, renderPass: renderPass, verticesBuffer: voBuffer)
        }
    }
    
    private func encodeVertexPass(commandBuffer: MTLCommandBuffer, renderPass: RenderPass, outputBuffer: MTLBuffer) {
        var vertices = renderPass.vertices.map { $0.xyz }
        var colors = renderPass.vertices.map { $0.color }
        var transform = renderPass.transform
        var screenSize = simd_long2(renderPass.colorBuffer.width, renderPass.colorBuffer.height)
        
        commandBuffer.compute { encoder in
            encoder.set(array: &vertices, index: 0)
            encoder.set(array: &colors, index: 1)
            encoder.set(value: &transform, index: 2)
            encoder.set(value: &screenSize, index: 3)
            encoder.setBuffer(outputBuffer, offset: 0, index: 4)
            
            encoder.dispatch1d(state: vertexPassComputePipelineState, exactly: vertices.count)
        }
    }
    
    private func encodeRasterizerPass(commandBuffer: MTLCommandBuffer, renderPass: RenderPass, verticesBuffer: MTLBuffer) {
        let vertices = verticesBuffer.contents().assumingMemoryBound(to: VO.self)

        let indicesPerPrimitive = renderPass.primitiveType.verticesCount
        let texture = renderPass.colorBuffer.texture!
        let zTexture = renderPass.depthBuffer.texture!
        
        let primitivesCount = renderPass.indices.count / indicesPerPrimitive
        for primitiveIndex in 0..<primitivesCount {
            let base = primitiveIndex * indicesPerPrimitive
            let indices = renderPass.indices[base..<(base + indicesPerPrimitive)]

            let vs = indices.map { vertices[$0].pos.xyz.xy }
            let a = vs[0]
            let b = vs[1]
            let c = vs[2]
                
            let sorted = [a, b, c].sorted { $0.y < $1.y }.map { simd_uint2($0) }
            let xSorted = [a, b, c].sorted { $0.x < $1.x }.map { simd_uint2($0) }

            let minY = sorted.first!.y
            let maxY = sorted.last!.y
            let minX = xSorted.first!.x
            let maxX = xSorted.last!.x
            let height = maxY - minY + 1
            let width = maxX - minX + 1
            
            var offset = simd_uint2(minX, minY)
            var ti = simd_long3(indices[base + 0], indices[base + 1], indices[base + 2])
            guard width != 0, height != 0 else {
                continue
            }
            commandBuffer.compute { encoder in
                encoder.set(value: &offset, index: 0)
                encoder.setBuffer(verticesBuffer, offset: 0, index: 1)
                encoder.set(value: &ti, index: 2)
                encoder.setTexture(texture, index: 0)
                encoder.setTexture(zTexture, index: 1)
                encoder.dispatch2d(
                    state: rasterizerPassComputePipelineState,
                    size: MTLSize(width: Int(width), height: Int(height), depth: texture.depth)
                )
            }
        }
    }
}

extension MTLComputeCommandEncoder {
    func set<T>(array: inout [T], index: Int) {
        setBytes(array, length: MemoryLayout.stride(ofValue: array[0]) * array.count, index: index)
    }
}
