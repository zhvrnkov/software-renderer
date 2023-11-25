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

    var thickness: Int
}

struct Triangle {
    var a: vector_long2
    var b: vector_long2
    var c: vector_long2
}

extension Pixel {
    static func floats(b: Float, g: Float, r: Float, a: Float) -> Pixel {
        self.init(
            b: UInt8(b * Float(UInt8.max)),
            g: UInt8(g * Float(UInt8.max)),
            r: UInt8(r * Float(UInt8.max)),
            a: UInt8(a * Float(UInt8.max))
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

    func render(image: Image) {
        defer {
            time += 1 / 60
        }
        let width = 1
        let height = 1

        //        for y in 0..<height {
        //            for x in 0..<width {
        //                let cellW = image.width / width
        //                let cellH = image.height / height
        //                let cellX = x * cellW
        //                let cellY = y * cellH
        //
        //                let cellCX = cellX + cellW / 2
        //                let cellCY = cellY + cellH / 2
        //
        //                draw(circle: Circle(x: cellCX, y: cellCY, r: cellW / 4), with: .floats(b: 1, g: 0, r: 0, a: 1), in: image)
        //            }
        //        }

        //        let line = Line(x0: 64, y0: 64, x1: 512 - 64, y1: 512 - 64, thickness: 14)
        //        draw(line: line, with: .floats(b: 0, g: 1, r: 0, a: 1), in: image)
        //
        //        let line2 = Line(x0: 64, y0: 64, x1: 64, y1: 512 - 64, thickness: 14)
        //        draw(line: line2, with: .floats(b: 1, g: 0, r: 0, a: 1), in: image)

        //        let line3 = Line(x0: 64, y0: 64, x1: 512 - 64, y1: 512 - 64, thickness: 14)
        //        draw(line: line3, with: .floats(b: 0, g: 0, r: 1, a: 1), in: image)

        let rect = Rect(x: 0, y: 0, w: 512, h: 512)
        draw(rect: rect, with: .floats(b: 0, g: 0, r: 0, a: 1), in: image)

        let triangle = Triangle(a: vector_long2(69, 59), b: vector_long2(59, 69), c: vector_long2(443, 453))
        draw(triangle: triangle, with: .floats(b: 0, g: 0, r: 1, a: 1), in: image)

        let tr2 = Triangle(a: vector_long2(0, 0), b: vector_long2(0, 64), c: vector_long2(64, 0))
        draw(triangle: tr2, with: .floats(b: 1, g: 0, r: 0, a: 1), in: image)

        let tr3 = Triangle(a: vector_long2(64, 64), b: vector_long2(0, 64), c: vector_long2(64, 0))
        draw(triangle: tr3, with: .floats(b: 1, g: 1, r: 0, a: 1), in: image)

        let tr4 = Triangle(a: vector_long2(128, 128), b: vector_long2(128 - 14, 128 + 64), c: vector_long2(128 + 14, 128 + 64))
        draw(triangle: tr4, with: .floats(b: 1, g: 0, r: 1, a: 1), in: image)

        let tr5 = Triangle(a: vector_long2(128, 256), b: vector_long2(128 - 14, 128 + 64), c: vector_long2(128 + 14, 128 + 64))
        draw(triangle: tr5, with: .floats(b: 1, g: 0.5, r: 1, a: 1), in: image)

        let center = vector_float2(256, 256)
        let a = center + vector_float2(cos(time), sin(time)) * 128
        let tr6 = Triangle(a: vector_long2(a), b: vector_long2(256 - 14, 256), c: vector_long2(256 + 14, 256))
        draw(triangle: tr6, with: .floats(b: 1, g: 1.0, r: 1, a: 1), in: image)

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
        let r2 = circle.r * circle.r
        for dy in stride(from: -circle.r, to: circle.r, by: circle.r.signum()) {
            for dx in stride(from: -circle.r, to: circle.r, by: circle.r.signum()) {
                let ls = dx * dx + dy * dy
                guard ls <= r2 else {
                    continue
                }
                let y = circle.y + dy
                let x = circle.x + dx
                pointer.advanced(by: y * image.width + x).pointee = color
            }
        }
    }

    func draw(line: Line, with color: Pixel, in image: Image) {
        var pointer = image.pixelsPointer
        //        var t = 0.0
        //        let dt = 1.0 / Double(abs(line.x1 - line.x0))
        //        for x in stride(from: line.x0, to: line.x1, by: line.x1.signum()) {
        //            let y = Double(line.y0) + Double(line.y1 - line.y0) * t
        //            t += dt
        //            let half = (Double(line.thickness) / 2).rounded()
        //            for dy in stride(from: -half + 1, to: half, by: 1) {
        //                pointer[x, Int((y + dy).rounded()), image.width] = color
        //            }
        //        }


        var p0 = vector_float2(Float(line.x0), Float(line.y0))
        var p1 = vector_float2(Float(line.x1), Float(line.y1))
        var dir = p1 - p0
        dir = normalize(vector_float2(-dir.y, dir.x)) * Float(line.thickness) / 2

        let a = vector_long2((p0 + dir).rounded(.toNearestOrAwayFromZero))
        let b = vector_long2((p0 - dir).rounded(.toNearestOrAwayFromZero))
        let c = vector_long2((p1 + dir).rounded(.toNearestOrAwayFromZero))
        let d = vector_long2((p1 - dir).rounded(.toNearestOrAwayFromZero))

        let minY = min(a.y, b.y, c.y, d.y)
        let maxY = max(a.y, b.y, c.y, d.y)
        let minX = Float(min(a.x, b.x, c.x, d.x))
        let maxX = Float(max(a.x, b.x, c.x, d.x))

        let leftMostPoint = a // [a,b,c,d].min { $0.x < $1.x }!
        let rightMostPoint = d // [a,b,c,d].max { $0.x < $1.x }!

        func normy(_ y: Int) -> Float {
            return (Float(y) - Float(minY)) / Float(maxY - minY)
        }

        for y in stride(from: minY, to: maxY, by: 1) {
            let t = normy(y)
            let leftX: Int = {
                return Int(interpolate(a: Float(b.x), bv: vector_float2(normy(leftMostPoint.y), Float(leftMostPoint.x)), c: Float(c.x), t: t).rounded())
            }()
            let rightX: Int = {
                return Int(interpolate(a: Float(b.x), bv: vector_float2(normy(rightMostPoint.y), Float(rightMostPoint.x)), c: Float(c.x), t: t).rounded())
            }()
            for x in stride(from: leftX, to: rightX, by: 1) {
                pointer[x, y, image.width] = color
            }
        }
    }

    func draw(triangle: Triangle, with color: Pixel, in image: Image) {
        var pointer = image.pixelsPointer

        let sorted = [triangle.a, triangle.b, triangle.c].sorted { $0.y < $1.y }
        let leftVertices = [sorted[0], sorted[1], sorted[2]]
        let rightVertices = [sorted[0], sorted[2]]

        let a = triangle.a
        let b = triangle.b
        let c = triangle.c
        let minY = min(a.y, b.y, c.y)
        let maxY = max(a.y, b.y, c.y)

        for y in stride(from: minY, to: maxY, by: 1) {
            let leftX: Int = {
                return Int(interpolate(values: leftVertices.map { vector_float2(Float($0.y), Float($0.x)) }, t: Float(y)).rounded())
            }()
            let rightX: Int = {
                    return Int(interpolate(values: rightVertices.map { vector_float2(Float($0.y), Float($0.x)) }, t: Float(y)).rounded())
            }()
            for x in stride(from: min(leftX, rightX), to: max(leftX, rightX), by: 1) {
                pointer[x, y, image.width] = color
            }
        }
    }

    func interpolate(values: [vector_float2], t: Float) -> Float {
        var baseIndex = 0
        for (index, value) in values.enumerated() {
            if t >= value.x {
                baseIndex = index
            }
        }
        let nextIndex = baseIndex + 1

        let normalizedT = (t - values[baseIndex].x) / (values[nextIndex].x - values[baseIndex].x)

        let value = values[baseIndex].y + (values[nextIndex].y - values[baseIndex].y) * normalizedT
        if value.isNaN || value.isInfinite {
            fatalError()
        }
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
