//
//  RealityKit+Extensions.swift
//  renderer
//
//  Created by Vlad on 08.12.2023.
//

import Foundation
import RealityKit

extension MeshResource {
    var vertices: MeshBuffer<simd_float3> {
        buffers[.positions]!.get(simd_float3.self)!
    }
    
    var indices: MeshBuffer<UInt16> {
        buffers[.triangleIndices]!.get(UInt16.self)!
    }
    
    var normals: MeshBuffer<simd_float3> {
        buffers[.normals]!.get(simd_float3.self)!
    }
    
    private var buffers: [MeshBuffers.Identifier: AnyMeshBuffer] {
        contents.models["MeshModel"]!.parts["MeshPart"]!.buffers
    }
}

