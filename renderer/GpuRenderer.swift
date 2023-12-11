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
    lazy var roiPassComputePipelineState = try! context.makeComputePipelineState(
        functionName: "roi_pass"
    )
    lazy var rasterizerPassComputePipelineState = try! context.makeComputePipelineState(
        functionName: "rasterizer_pass"
    )
    lazy var reduceComputePipelineState = try! context.makeComputePipelineState(
        functionName: "reduce"
    )
    var vertexOutBuffer: MTLBuffer?
    var roisBuffer: MTLBuffer?
    var verticesBuffer: MTLBuffer?
    var colorsBuffer: MTLBuffer?

    func render(renderPass: RenderPass) {
        
        let texture = renderPass.colorBuffer.texture!
        let depthTexture = renderPass.depthBuffer.texture!
        let vertices = renderPass.vertices
        
        let voBuffer: MTLBuffer = {
            let length = vertices.count * MemoryLayout<VO>.stride
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
        let primitivesCount = renderPass.indices.count / renderPass.primitiveType.verticesCount
//        let roiBuffer: MTLBuffer = {
//            let length = primitivesCount * MemoryLayout<simd_uint4>.stride
//            if let roisBuffer,
//               roisBuffer.length == length {
//                return roisBuffer
//            } else {
//                let newBuffer = context.device.makeBuffer(
//                    length: length, options: .storageModeShared
//                )!
//                self.roisBuffer = newBuffer
//                return newBuffer
//            }
//        }()
        let indicesBuffer: MTLBuffer = {
            var indices = renderPass.indices
            return context.device.makeBuffer(bytes: &indices, length: indices.count * MemoryLayout.stride(ofValue: indices[0]))!
        }()
        
        context.scheduleAndWait { commandBuffer in
            commandBuffer.compute { encoder in
                encoder.setTexture(depthTexture, index: 0)
                encoder.dispatch2d(state: clearDepthComputePipelineState, size: depthTexture.size)
            }
            commandBuffer.clear(texture: texture, color: .init())
            encodeVertexPass(commandBuffer: commandBuffer, renderPass: renderPass, outputBuffer: voBuffer)
            commandBuffer.compute { encoder in
                encoder.setBuffer(voBuffer, offset: 0, index: 0)
                encoder.setBuffer(indicesBuffer, offset: 0, index: 1)
//                encoder.setBuffer(texture, offset: 0, index: 2)
                encoder.setTexture(texture, index: 0)
                encoder.setTexture(renderPass.depthBuffer.texture!, index: 1)
                encoder.dispatch1d(state: roiPassComputePipelineState, exactly: primitivesCount)
                print(roiPassComputePipelineState.threadExecutionWidth)
            }
        }

        var input: [Int32] = (0..<8096).map { Int32($0) }
        let inputSum = input.reduce(0) { $0 + $1 }
        var output: Int32 = 0
        let inputBuffer = context.device.makeBuffer(bytes: &input, length: input.count * 4, options: .storageModeShared)
        let outputBuffer = context.device.makeBuffer(length: 4, options: .storageModeShared)
        print(inputSum, outputBuffer!.contents().assumingMemoryBound(to: Int32.self).pointee)
        context.scheduleAndWait { commandBuffer in
            commandBuffer.compute { encoder in
                let threadsPerThreadgroup = MTLSize(width: reduceComputePipelineState.threadExecutionWidth, height: 1, depth: 1)
                let threadgroupsPerGrid = MTLSize(width: 1, height: 1, depth: 1)

                encoder.setBuffer(inputBuffer, offset: 0, index: 0)
                encoder.setBuffer(outputBuffer, offset: 0, index: 1)
                encoder.setThreadgroupMemoryLength(threadsPerThreadgroup.width * MemoryLayout<Int32>.stride, index: 0)

                encoder.setComputePipelineState(reduceComputePipelineState)
                encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            }
        }
        print(inputSum, outputBuffer!.contents().assumingMemoryBound(to: Int32.self).pointee)
        exit(0)
//        context.scheduleAndWait { commandBuffer in
//            encodeRasterizerPass(commandBuffer: commandBuffer, renderPass: renderPass, verticesBuffer: voBuffer, indicesBuffer: indicesBuffer, roiBuffer: roiBuffer)
//        }
    }
    
    private func encodeVertexPass(commandBuffer: MTLCommandBuffer, renderPass: RenderPass, outputBuffer: MTLBuffer) {
        var vertices = renderPass.vertices.map { $0.xyz }
        var colors = renderPass.vertices.map { $0.color }
        var transform = renderPass.transform
        var screenSize = simd_long2(renderPass.colorBuffer.width, renderPass.colorBuffer.height)
        
        commandBuffer.compute { encoder in
            encoder.set(array: &vertices, index: 0, buffer: &verticesBuffer)
            encoder.set(array: &colors, index: 1, buffer: &colorsBuffer)
            encoder.set(value: &transform, index: 2)
            encoder.set(value: &screenSize, index: 3)
            encoder.setBuffer(outputBuffer, offset: 0, index: 4)
            
            encoder.dispatch1d(state: vertexPassComputePipelineState, exactly: vertices.count)
        }
    }
    
    private func encodeRasterizerPass(commandBuffer: MTLCommandBuffer, renderPass: RenderPass, verticesBuffer: MTLBuffer, indicesBuffer: MTLBuffer, roiBuffer: MTLBuffer) {
        let rois = roiBuffer.contents().assumingMemoryBound(to: simd_uint4.self)

        let indicesPerPrimitive = renderPass.primitiveType.verticesCount
        let texture = renderPass.colorBuffer.texture!
        let zTexture = renderPass.depthBuffer.texture!
        
        let primitivesCount = renderPass.indices.count / indicesPerPrimitive
        for primitiveIndex in 0..<primitivesCount {
            let rect: (offset: simd_uint2, size: simd_long2) = (
                rois[primitiveIndex].lowHalf,
                simd_long2(Int(rois[primitiveIndex].z), Int(rois[primitiveIndex].w))
            )
            guard rect.offset.x != 0, rect.offset.y != 0 else {
                continue
            }
            commandBuffer.compute { encoder in
                var offset = rect.offset
                var primitiveIndex = primitiveIndex
                encoder.set(value: &offset, index: 0)
                encoder.setBuffer(verticesBuffer, offset: 0, index: 1)
                encoder.setBuffer(indicesBuffer, offset: 0, index: 2)
                encoder.set(value: &primitiveIndex, index: 3)
                encoder.setTexture(texture, index: 0)
                encoder.setTexture(zTexture, index: 1)
                encoder.dispatch2d(
                    state: rasterizerPassComputePipelineState,
                    size: MTLSize(width: rect.size.x, height: rect.size.y, depth: texture.depth)
                )
            }
        }
    }
}

extension MTLComputeCommandEncoder {
    func set<T>(array: inout [T], index: Int, buffer: inout MTLBuffer?) {
        let length = MemoryLayout.stride(ofValue: array[0]) * array.count
        if length <= 4096 {
            setBytes(array, length: length, index: index)
        } else {
            if let buffer,
               buffer.length == length {
                buffer.contents().copyMemory(from: array, byteCount: length)
                setBuffer(buffer, offset: 0, index: index)
            } else {
                let newBuffer = device.makeBuffer(length: length, options: .storageModeShared)!
                newBuffer.contents().copyMemory(from: array, byteCount: length)
                buffer = newBuffer
                setBuffer(newBuffer, offset: 0, index: index)
            }
        }
    }
}
