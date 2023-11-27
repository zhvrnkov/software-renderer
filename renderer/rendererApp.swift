//
//  rendererApp.swift
//  renderer
//
//  Created by Владислав Жаворонков on 24.11.2023.
//

import SwiftUI
import MetalKit

struct MetalView: UIViewRepresentable {

    typealias UIViewType = MTKView
    typealias ViewUpdater = (Image) -> Void

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

        static let width = 256
        static let height = 256
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
                let image = Image(
                    pointer: contents,
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

struct Image {
    let pointer: UnsafeMutableRawPointer
    let width: Int
    let height: Int
    let bytesPerRow: Int

    var pixelsPointer: UnsafeMutablePointer<Pixel> {
        pointer.assumingMemoryBound(to: Pixel.self)
    }
}

struct Pixel {
    var b: UInt8
    var g: UInt8
    var r: UInt8
    var a: UInt8
}

struct Rect {
    var x: Int
    var y: Int
    var w: Int
    var h: Int
}

struct Circle {
    var x: Int
    var y: Int
    var r: Int
}

struct Line {
    var x0: Int
    var y0: Int
    var x1: Int
    var y1: Int
}

struct Triangle {
    var a: vector_long2
    var b: vector_long2
    var c: vector_long2

    func xy(ws: vector_float3) -> vector_float2 {
        let af = vector_float2(a)
        let bf = vector_float2(b)
        let cf = vector_float2(c)
        return af * ws.x + bf * ws.y + cf * ws.z
    }

    func ws(xy: vector_float2) -> vector_float3 {
        let af = vector_float2(a) + 0.5
        let bf = vector_float2(b) + 0.5
        let cf = vector_float2(c) + 0.5
        let T = matrix_float2x2(columns: ((af - cf), (bf - cf)))
        let wab = T.inverse * (xy - cf)
        return vector_float3(wab.x, wab.y, 1 - wab.x - wab.y)
    }

    func inside(_ xy: vector_float2) -> Bool {
        let ws = self.ws(xy: xy)
        return 0 <= ws.x && ws.x <= 1 &&
        0 <= ws.y && ws.y <= 1 &&
        0 <= ws.z && ws.z <= 1
    }
}

struct Triangle3d {
    var a: vector_long3
    var b: vector_long3
    var c: vector_long3
}

extension Pixel {
    static func floats(b: Float, g: Float, r: Float, a: Float) -> Pixel {
        self.init(
            b: UInt8(simd_clamp(b, 0, 1.0) * Float(UInt8.max)),
            g: UInt8(simd_clamp(g, 0, 1.0) * Float(UInt8.max)),
            r: UInt8(simd_clamp(r, 0, 1.0) * Float(UInt8.max)),
            a: UInt8(simd_clamp(a, 0, 1.0) * Float(UInt8.max))
        )
    }
}


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
    let width = MetalView.Coordinator.width
    let height = MetalView.Coordinator.height

    func render(image: Image) {
        defer {
            time += 1 / 60
        }

        draw(rect: Rect(x: 0, y: 0, w: width, h: height), with: .floats(b: 0, g: 0, r: 0, a: 1), in: image)
        
        let pad = width / 8
        let tr1 = Triangle3d(
            a: vector_long3(pad, pad, 1),
            b: vector_long3(width - pad, pad, 0),
            c: vector_long3(pad, height - pad, 1)
        )
        let ptr1 = project(triangle3d: tr1)
        draw(triangle: ptr1, with: .floats(b: 0, g: 0, r: 0, a: 1), in: image)
        
        let tr2 = Triangle3d(
            a: tr1.b, b: tr1.c,
            c: vector_long3(width - pad, height - pad, 0)
        )
        let ptr2 = project(triangle3d: tr2)
        draw(triangle: ptr2, with: .floats(b: 0, g: 0, r: 0, a: 1), in: image)
        var pointer = image.pixelsPointer
        
//        pointer[ptr1.a.x, ptr1.a.y, image.width] = .floats(b: 1, g: 1, r: 1, a: 1)
//        pointer[ptr1.b.x, ptr1.b.y, image.width] = .floats(b: 1, g: 1, r: 1, a: 1)
//        pointer[ptr1.c.x, ptr1.c.y, image.width] = .floats(b: 1, g: 1, r: 1, a: 1)

    }
    
    func rotationTriangleExample(image: Image) {
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
        draw(triangle: triangle, with: .floats(b: 0, g: 0, r: 1, a: 1), in: image)
    }

    func draw(rect: Rect, with color: Pixel, in image: Image) {
        let pointer = image.pixelsPointer
        for y in stride(from: rect.y, to: rect.y + rect.w, by: rect.w.signum()) {
            for x in stride(from: rect.x, to: rect.x + rect.h, by: rect.h.signum()) {
                pointer.advanced(by: y * image.width + x).pointee = color
            }
        }
    }

    func draw(circle: Circle, with color: Pixel, in image: Image) {
        let pointer = image.pixelsPointer
        for dy in stride(from: -circle.r, to: circle.r, by: circle.r.signum()) {
            for dx in stride(from: -circle.r, to: circle.r, by: circle.r.signum()) {
                let p = vector_float2(Float(dx), Float(dy)) + 0.5
                let l = length(p)
                let r = Float(circle.r)
                let d: Float
                if l < r-2 {
                    d = 1.0
                } else {
                    d = simd_clamp(simd_smoothstep(r+2, r-2, l), 0, 1)
                }
                let y = circle.y + dy
                let x = circle.x + dx
                pointer.advanced(by: y * image.width + x).pointee = .floats(b: d, g: 0, r: 0, a: 1)
            }
        }
    }

    func draw(line: Line, with color: Pixel, in image: Image) {
        var pointer = image.pixelsPointer
        let dx = line.x1 - line.x0
        let dy = line.y1 - line.y0
        let steps = max(dx, dy)
        let xStep = Float(dx) / Float(steps)
        let yStep = Float(dy) / Float(steps)

        var x = Float(line.x0)
        var y = Float(line.y0)
        for _ in 0..<steps {
            pointer[Int(x.rounded()), Int(y.rounded()), image.width] = color
            x += xStep
            y += yStep
        }
    }

    func draw(triangle: Triangle, with color: Pixel, in image: Image) {
        var pointer = image.pixelsPointer

        let sorted = [triangle.a, triangle.b, triangle.c].sorted { $0.y < $1.y }
        let leftVertices = [sorted[0], sorted[1], sorted[2]]
        let rightVertices = [sorted[0], sorted[2]]

        func aa(x: Int, y: Int) -> Float {
            let c = vector_float2(Float(x), Float(y))
            var acc: Float = 0
            let multisampleCount = 1
            guard multisampleCount > 1 else {
                return 1
            }
            let step = 1 / Float(multisampleCount * multisampleCount)
            for dy in stride(from: 1, through: multisampleCount, by: 1) {
                for dx in stride(from: 1, through: multisampleCount, by: 1) {
                    let p = c + vector_float2(Float(dx), Float(dy)) / Float(multisampleCount + 1)
                    acc += triangle.inside(p) ? step : 0
                }
            }
            return acc
        }

        func setPixel(x: Int, y: Int, a: Float) {
            let ws = triangle.ws(xy: vector_float2(Float(x), Float(y)) + 0.5)
            let ac = vector_float3(1, 0, 0)
            let bc = vector_float3(0, 1, 0)
            let cc = vector_float3(0, 0, 1)
            let color = (ac * ws.x + bc * ws.y + cc * ws.z) * a
            pointer[x, y, image.width] = .floats(b: color.z, g: color.y, r: color.x, a: 1)
        }

        for y in stride(from: sorted.first!.y, through: sorted.last!.y, by: 1) {
            var leftX = interpolate(values: leftVertices, t: y)
            var rightX = interpolate(values: rightVertices, t: y)
            if leftX > rightX {
                swap(&leftX, &rightX)
            }
            for x in stride(from: leftX + 1, to: rightX, by: 1) {
                setPixel(x: x, y: y, a: 1)
            }
            setPixel(x: leftX, y: y, a: aa(x: leftX, y: y))
            setPixel(x: rightX, y: y, a: aa(x: rightX, y: y))
        }
    }

    func interpolate(values: [vector_long2], t: Int) -> Int {
        var baseIndex = 0
        for (index, value) in values.enumerated() {
            if t >= value.y {
                baseIndex = index
            }
        }
        let nextIndex = baseIndex + 1
        let startValue = values[baseIndex]
        guard values.indices.contains(nextIndex) else {
            return startValue.x
        }
        let endValue = values[nextIndex]
        let start = startValue.x
        let end = endValue.x
        let diff = end - start
        let dy = endValue.y - startValue.y

        let nt = (t - startValue.y)

        let value = start + diff * nt / dy
        return value
    }

    func interpolate(a: Float, bv: vector_float2, c: Float, t: Float) -> Float {
        let b = bv.y
        let bp = bv.x

        let toBP = t / bp
        if toBP < 1.0 {
            return a + (b - a) * toBP
        } else {
            return b + (c - b) * ((t - bp) / (1.0 - bp))
        }
    }
    
    func project(triangle3d: Triangle3d) -> Triangle {
        // near = 0
        // far = 10
        
        return Triangle(
            a: triangle3d.a.xy,
            b: triangle3d.b.xy,
            c: triangle3d.c.xy
        )
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
