//
//  rendererApp.swift
//  renderer
//
//  Created by Владислав Жаворонков on 24.11.2023.
//

import SwiftUI
import MetalKit
import struct RealityKit.Transform
import class RealityKit.MeshResource

// TODO: Depth buffer
// TODO: normalized coordinates
// TODO: port to GPU with Compute shaders

struct MetalView: UIViewRepresentable {

    typealias UIViewType = MTKView
    typealias ViewUpdater = (ColorImage) -> Void

    let context = MTLContext.shared
    let viewUpdater: ViewUpdater

    func makeCoordinator() -> Coordinator {
        return Coordinator(viewUpdater: viewUpdater)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: self.context.device)
        view.layer.minificationFilter = .nearest
        view.layer.magnificationFilter = .nearest
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = .init(width: Coordinator.width, height: Coordinator.height)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let context = MTLContext.shared
        let viewUpdater: ViewUpdater
        let buffer: MTLBuffer
        let texture: MTLTexture

        static let width = 512
        static let height = 512
        static let bytesPerRow = width * 4

        init(viewUpdater: @escaping ViewUpdater) {
            self.viewUpdater = viewUpdater
            let length = Self.bytesPerRow * Self.height
            buffer = context.device.makeBuffer(length: length, options: .storageModeShared)!

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.width, height: Self.height, mipmapped: false)
            descriptor.resourceOptions = buffer.resourceOptions
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            texture = buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: Self.bytesPerRow)!
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        }

        func draw(in view: MTKView) {
            context.scheduleAndWait { commandBuffer in
                guard let drawable = view.currentDrawable else {
                    return
                }
                let contents = buffer.contents()
                let width = Self.width
                let height = Self.height
                let bytesPerRow = Self.bytesPerRow
                let image = ColorImage(
                    pointer: contents.assumingMemoryBound(to: Pixel.self),
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow
                )
                viewUpdater(image)
                commandBuffer.copy(from: texture, to: drawable.texture)
                //                commandBuffer.clear(texture: drawable.texture, color: MTLClearColor(red: 1, green: 1, blue: 0, alpha: 1))
                commandBuffer.present(drawable)
            }
        }
    }
}


//let mesh = MeshResource.generateSphere(radius: 0.25)
//let vertices = zip(mesh.vertices.elements, mesh.normals.elements).map { (xyz, normal) in Vertex(xyz: xyz, color: abs(normal)) }
//let indices: [Int] = {
//    var indices = [Int]()
//    mesh.indices.forEach { x, y, z in
//        indices.append(Int(x))
//        indices.append(Int(y))
//        indices.append(Int(z))
//    }
//    return indices
//}()

let mesh = MDLMesh(sphereWithExtent: simd_float3(repeating: 0.4), segments: [10, 10], inwardNormals: false, geometryType: .triangles, allocator: nil)
//let mesh = MDLMesh.newBox(withDimensions: .init(0.5), segments: .init(2), geometryType: .triangles, inwardNormals: false, allocator: nil)
let submesh = (mesh.submeshes![0] as! MDLSubmesh)
let indexBuffer = submesh.indexBuffer
let vertexBuffer = mesh.vertexBuffers[0]
typealias MDLVertex = (x: Float, y: Float, z: Float, nx: Float, ny: Float, nz: Float, u: Float, v: Float)
let mdlVertices = Array(UnsafeBufferPointer(
    start: vertexBuffer.map().bytes.assumingMemoryBound(to: MDLVertex.self), count: mesh.vertexCount
))
let vertices = mdlVertices.map { Vertex(xyz: simd_float3($0.x, $0.y, $0.z), color: abs(simd_float3($0.nx, $0.ny, $0.nz))) }
let indices = Array(UnsafeBufferPointer(start: indexBuffer.map().bytes.assumingMemoryBound(to: UInt16.self), count: submesh.indexCount)).map { Int($0) }

@main
struct rendererApp: App {
    var body: some Scene {
        WindowGroup {
            MetalView { image in
                render(image: image)
            }
        }
        .defaultSize(width: 1024, height: 1024)
    }

    @State var time: Float = 0
    let renderer = Renderer()
    let width = MetalView.Coordinator.width
    let height = MetalView.Coordinator.height

    func render(image: ColorImage) {
        defer {
            time += 1 / 60
        }
        var depthImage: DepthImage = {
            var depthBuffer = [Float](repeating: .infinity, count: image.width * image.height)
            let depthPointer = depthBuffer.withUnsafeMutableBufferPointer {
                $0.baseAddress!
            }
            
            return DepthImage(
                pointer: depthPointer, width: image.width, height: image.height, bytesPerRow: image.width * MemoryLayout<Float>.stride)
        }()
        
//        var a = Vertex(xyz: .init(0, 1,  0.0), color: .init(1, 0, 0))
//        var b = Vertex(xyz: .init(1, 0,  0.0), color: .init(0, 1, 0))
//        var c = Vertex(xyz: .init(-1, 0, 0.0), color: .init(0, 0, 1))
//        var vertices = [a,b,c]
        
        var renderPass = RenderPass(colorBuffer: image, depthBuffer: depthImage, vertices: vertices, indices: indices)
        renderPass.primitiveType = .triangle
        
//        print(mesh)
//        print(mesh.contents.models["MeshModel"]!.parts["MeshPart"]!.buffers[.triangleIndices]?.get(UInt16.self)!.elements)
        
        var transform = Transform()
        transform.rotation = simd_quatf(angle: time, axis: normalize(simd_float3(1.0, 1.0, 0)))
        transform.rotation *= simd_quatf(angle: time * 0.5, axis: simd_float3(0, 0, 1))
        transform.translation = simd_float3(0, 0, 1)
//        transform.scale = max(1.0 - time * 0.01, 0) * simd_float3(repeating: 2.0)
        transform.scale = simd_float3(repeating: 2.0)
        
        let projectionMatrix = matrix_float4x4(rows: [
            simd_float4(1, 0, 0, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(0, 0, 1, 1), // z + 1
        ])
        
        renderPass.transform = projectionMatrix * transform.matrix
        
        renderer.render(renderPass: renderPass)
//        renderer.clear(image: image, with: .floats(b: 0, g: 0, r: 0, a: 1))
//        trianglesExample(image: image)
    }
    
    func rotationTriangleExample(image: ColorImage) {
        let angle = time
        let t = matrix_float2x2(columns: (
            vector_float2(cos(angle), sin(angle)),
            vector_float2(cos(angle + Float.pi / 2), sin(angle + Float.pi / 2))
        )
        )
        let pad = width / 4
        var triangle = Triangle(a: vector_long2(width / 2, pad), b: vector_long2(pad, width / 2), c: vector_long2(width - pad, width - pad))
        let center = vector_float2(Float(width / 2), Float(height / 2))
        triangle.a = vector_long2((t * (vector_float2(triangle.a) - center)) + center)
        triangle.b = vector_long2((t * (vector_float2(triangle.b) - center)) + center)
        triangle.c = vector_long2((t * (vector_float2(triangle.c) - center)) + center)
        renderer.draw(triangle: triangle, with: .floats(b: 0, g: 0, r: 1, a: 1), in: image)
    }

    func cubeExample(image: ColorImage) {
        let pad = width / 4
        let width = width - pad - pad
        let height = height - pad - pad
        let depth = width

        let transform: matrix_float3x3 = {
            let yRot = matrix_float3x3(
                simd_quatf(angle: time * 0.5, axis: .init(x: 0, y: 1, z: 0))
            )
            let xRot = matrix_float3x3(
                simd_quatf(angle: time * 0.1 + 1.2, axis: .init(x: 1, y: 0, z: 0))
            )
            return yRot * xRot
        }()
        func apply(to p: vector_long3) -> vector_long3 {
            let center = vector_float3(
                Float(self.width) / 2,
                Float(self.height) / 2,
                Float(depth) / 2
            )
            var fp = vector_float3(p)
            fp = fp - center
            fp = transform * fp
            fp = fp + center

            return vector_long3(fp.rounded(.toNearestOrAwayFromZero))
        }

        let a0 = vector_long3(pad, pad, 0)
        let b0 = vector_long3(pad + width, pad, 0)
        let c0 = vector_long3(pad, pad + height, 0)
        let d0 = vector_long3(pad + width, pad + height, 0)
        let a1 = vector_long3(pad, pad, depth)
        let b1 = vector_long3(pad + width, pad, depth)
        let c1 = vector_long3(pad, pad + height, depth)
        let d1 = vector_long3(pad + width, pad + height, depth)
        var faces = [
            [a0, b0, c0, d0],
            [a1, b1, c1, d1],
            [a1, a0, c1, c0],
            [b1, b0, a1, a0],
            [b0, b1, d0, d1],
            [c0, c1, d0, d1]
        ]
        
        func drawFace(abcd: [vector_long3]) {
            let a = apply(to: abcd[0])
            let b = apply(to: abcd[1])
            let c = apply(to: abcd[2])
            let d = apply(to: abcd[3])
            renderer.draw(
                line3d: Line3d(a: a, b: b),
                with: .floats(b: 0, g: 1, r: 0, a: 1),
                in: image
            )
            renderer.draw(
                line3d: Line3d(a: b, b: d),
                with: .floats(b: 0, g: 1, r: 0, a: 1),
                in: image
            )
            renderer.draw(
                line3d: Line3d(a: d, b: c),
                with: .floats(b: 0, g: 1, r: 0, a: 1),
                in: image
            )
            renderer.draw(
                line3d: Line3d(a: c, b: a),
                with: .floats(b: 0, g: 1, r: 0, a: 1),
                in: image
            )
        }
        
        for face in faces {
            drawFace(abcd: face)
        }
    }

    func trianglesExample(image: ColorImage) {
        var depthBuffer = [Float](repeating: .infinity, count: image.width * image.height)
        let depthPointer = depthBuffer.withUnsafeMutableBufferPointer {
            $0.baseAddress!
        }
        var depthImage = DepthImage(pointer: depthPointer, width: image.width, height: image.height, bytesPerRow: image.width * MemoryLayout<Float>.stride)

        let pad = width / 4
        let width = width - pad - pad
        let height = height - pad - pad
        let depth = width

        let transform: matrix_float3x3 = {
            let yRot = matrix_float3x3(
                simd_quatf(angle: time * 0.5, axis: .init(x: 0, y: 1, z: 0))
            )
            let xRot = matrix_float3x3(
                simd_quatf(angle: time * 0.1 + 1.2, axis: .init(x: 1, y: 0, z: 0))
            )
            return yRot // * xRot
        }()
        func apply(to p: vector_long3) -> vector_long3 {
            let center = vector_float3(
                Float(self.width) / 2,
                Float(self.height) / 2,
                Float(depth) / 2
            )
            var fp = vector_float3(p)
            fp = fp - center
            fp = transform * fp
            fp = fp + center
            
            return vector_long3(fp.rounded(.toNearestOrEven))
        }
        let triangle1: Triangle3d = {
            var tr = Triangle3d(
                a: .init(self.width / 2, pad, depth / 2),
                b: .init(self.width - pad, self.height - pad, depth / 2),
                c: .init(pad, self.height - pad, depth / 2)
            )
            tr.a = apply(to: tr.a)
            tr.b = apply(to: tr.b)
            tr.c = apply(to: tr.c)
            return tr
        }()
        let triangle2: Triangle3d = {
            var tr = Triangle3d(
                a: .init(self.width / 2, pad, depth / 2),
                b: .init(self.width / 2, self.height - pad, depth / 2 - pad),
                c: .init(self.width / 2, self.height - pad, depth / 2 + pad)
            )
            tr.a = apply(to: tr.a)
            tr.b = apply(to: tr.b)
            tr.c = apply(to: tr.c)
            return tr
        }()
        renderer.draw(triangle3d: triangle1, with: .floats(b: 1, g: 0, r: 0, a: 1), colorBuffer: image, depthBuffer: depthImage)
        renderer.draw(triangle3d: triangle2, with: .floats(b: 1, g: 0, r: 0, a: 1), colorBuffer: image, depthBuffer: depthImage)
    }
}

extension vector_long3 {
    var xy: vector_long2 {
        vector_long2(x, y)
    }
}

extension UnsafeMutablePointer {
    subscript(x: Int, y: Int, width: Int) -> Pointee {
        get {
            return self[y * width + x]
        }
        set {
            self[y * width + x] = newValue
        }
    }
}

extension simd_float2 {
    var angle: Float {
        let norm = normalize(self)
        var a = atan2(norm.y, norm.x)
        if a < 0 {
            a += 2 * Float.pi
        }
        return a
    }
}

extension Array {
    subscript(cycled index: Index) -> Element {
        self[(index + count) % count]
    }
}

