import Foundation
import simd

typealias ColorImage = Image<Pixel>
typealias DepthImage = Image<Float>

struct Image<Pixel> {
    let pointer: UnsafeMutablePointer<Pixel>
    let width: Int
    let height: Int
    let bytesPerRow: Int
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

struct Line3d {
    var a: vector_long3
    var b: vector_long3
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

final class Renderer {
    
    func clear(image: ColorImage, with color: Pixel) {
        draw(rect: Rect(x: 0, y: 0, w: image.width, h: image.height), with: color, in: image)
    }

    func draw(
        triangle3d: Triangle3d,
        with color: Pixel,
        in image: ColorImage,
        depthBuffer: DepthImage
    ) {
        let triangle = project(triangle3d: triangle3d)
        var pointer = image.pointer
        var depthPointer = depthBuffer.pointer

        let sorted = [triangle.a, triangle.b, triangle.c].sorted { $0.y < $1.y }
        let leftVertices = [sorted[0], sorted[1], sorted[2]]
        let rightVertices = [sorted[0], sorted[2]]

        func aa(x: Int, y: Int) -> Float {
            let c = vector_float2(Float(x), Float(y))
            var acc: Float = 0
            let multisampleCount = 2
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
            
            let za = Float(triangle3d.a.z)
            let zb = Float(triangle3d.b.z)
            let zc = Float(triangle3d.c.z)
            let depth: Float = (za * ws.x + zb * ws.y + zc * ws.z)
            guard depth < depthPointer[x, y, depthBuffer.width] else {
                return
            }
            depthPointer[x, y, depthBuffer.width] = depth

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

    func draw(line3d: Line3d, with color: Pixel, in image: ColorImage) {
        draw(line: project(line3d: line3d), with: color, in: image)
    }

    func draw(rect: Rect, with color: Pixel, in image: ColorImage) {
        let pointer = image.pointer
        for y in stride(from: rect.y, to: rect.y + rect.w, by: rect.w.signum()) {
            for x in stride(from: rect.x, to: rect.x + rect.h, by: rect.h.signum()) {
                pointer.advanced(by: y * image.width + x).pointee = color
            }
        }
    }

    func draw(circle: Circle, with color: Pixel, in image: ColorImage) {
        let pointer = image.pointer
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

    func draw(line: Line, with color: Pixel, in image: ColorImage) {
        var pointer = image.pointer
        let dx = line.x1 - line.x0
        let dy = line.y1 - line.y0
        let steps = max(abs(dx), abs(dy))
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

    func draw(triangle: Triangle, with color: Pixel, in image: ColorImage) {
        var pointer = image.pointer

        let sorted = [triangle.a, triangle.b, triangle.c].sorted { $0.y < $1.y }
        let leftVertices = [sorted[0], sorted[1], sorted[2]]
        let rightVertices = [sorted[0], sorted[2]]

        func aa(x: Int, y: Int) -> Float {
            let c = vector_float2(Float(x), Float(y))
            var acc: Float = 0
            let multisampleCount = 2
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
        return Triangle(
            a: project(vector_float3(triangle3d.a)),
            b: project(vector_float3(triangle3d.b)),
            c: project(vector_float3(triangle3d.c))
        )
    }
    
    func project(line3d: Line3d) -> Line {
        let a = project(vector_float3(line3d.a))
        let b = project(vector_float3(line3d.b))
        return Line(x0: a.x, y0: a.y, x1: b.x, y1: b.y)
    }
    
    func project(_ xyz: vector_float3) -> vector_long2 {
        let x0: Float = 0
        let y: Float = 0

        let w: Float = 512
        let h: Float = 512
        let zNear: Float = 256

        let c = vector_float3(w / 2, h / 2, -zNear)
        let xyzFromC = xyz - c
        let p = c + xyzFromC * (zNear / xyzFromC.z)
        return vector_long2(Int(p.x), Int(p.y))
    }
}
