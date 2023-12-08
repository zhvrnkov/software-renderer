import Foundation
import simd

typealias ColorImage = Image<Pixel>
typealias DepthImage = Image<Float>

class Image<Pixel> {
    init(pointer: UnsafeMutablePointer<Pixel>, width: Int, height: Int, bytesPerRow: Int) {
        self.pointer = pointer
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }
    
    private(set) var pointer: UnsafeMutablePointer<Pixel>
    let width: Int
    let height: Int
    let bytesPerRow: Int
    
    subscript(x: Int, y: Int) -> Pixel {
        get {
            guard contains(x: x, y: y) else {
                fatalError()
            }
            return pointer[x, y, width]
        }
        set {
            if contains(x: x, y: y) {
                pointer[x, y, width] = newValue
            } else {
                print(Self.self, #function, "\(x) and \(y) not in bounds")
            }
        }
    }
    
    func contains(x: Int, y: Int) -> Bool {
        return (0..<width).contains(x) && (0..<height).contains(y)
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
    
    init(float3: simd_float3) {
        self = .floats(b: float3.z, g: float3.y, r: float3.x, a: 1)
    }
}

// ndc to uv
func project(_ p: simd_float3) -> simd_float2 {
    return p.xy
    // eye located at (0, 0, -1) => p.z + 1 <=> p - e

    // that's why we need w component
    // we need to divide xy by something
    // or we will have projection matrix for each vertex

    let scale = 1 / (p.z + 1)
    let matrix = matrix_float2x2(diagonal: simd_float2(repeating: scale))
    var pp = matrix * p.xy
    // rotate since in ndc y up but in pixels y is down
    // convert to uv
    pp += 0.5
    return pp
}

func project(_ p: simd_float3) -> simd_long2 {
    let pp: simd_float2 = project(p)
    return simd_long2(Int(pp.x.rounded()), Int(pp.y.rounded()))
}

struct Vertex {
    // in NDC: x in -1...1; y in -1...1; z in 0...1
    let xyz: vector_float3
    let color: vector_float3
    
    func apply(transform: matrix_float4x4) -> Vertex {
        let xyzw = transform * simd_float4(xyz, 1)
        let xyz = xyzw.xyz / xyzw.w
        return Vertex(xyz: xyz, color: color)
    }
    
    func convertedToScreen(width: Int, height: Int) -> Vertex {
        let uv = xyz.xy * simd_float2(0.5, -0.5) + 0.5
        return Vertex(
            xyz: simd_float3(uv * simd_float2(Float(width), Float(height)).rounded(.toNearestOrAwayFromZero), xyz.z),
            color: color
        )
    }
}

enum PrimitiveType {
    case triangle
    case line
    case vertices
    
    var verticesCount: Int {
        switch self {
        case .triangle:
            return 3
        case .line:
            return 2
        case .vertices:
            return 3
        }
    }
}

struct RenderPass {
    var colorBuffer: ColorImage
    var depthBuffer: DepthImage
    
    var vertices: [Vertex]
    var indices: [Int]
    var primitiveType: PrimitiveType = .triangle
    
    var transform: matrix_float4x4 = .init(diagonal: .one)
}

final class Renderer {
    
    func render(renderPass: RenderPass) {
        clear(image: renderPass.colorBuffer, with: .floats(b: 0, g: 0, r: 0, a: 0))
        clear(image: renderPass.depthBuffer, with: .infinity)
        
        let indicesPerPrimitive = renderPass.primitiveType.verticesCount
        assert(renderPass.indices.count.isMultiple(of: indicesPerPrimitive))
        let draw: ([Vertex], ColorImage, DepthImage) -> Void = {
            switch renderPass.primitiveType {
            case .triangle:
                return draw(triangle:colorBuffer:depthBuffer:)
            case .line:
                return draw(line:colorBuffer:depthBuffer:)
            case .vertices:
                return draw(vertices:colorBuffer:depthBuffer:)
            }
        }()
        
        let primitivesCount = renderPass.indices.count / indicesPerPrimitive
        for primitiveIndex in 0..<primitivesCount {
            let base = primitiveIndex * indicesPerPrimitive
            let indices = renderPass.indices[base..<(base + indicesPerPrimitive)]
            let vertices = indices.map {
                renderPass.vertices[$0].apply(transform: renderPass.transform)
            }
            draw(vertices, renderPass.colorBuffer, renderPass.depthBuffer)
        }
    }
    
    func clear<T>(image: Image<T>, with color: T) {
        for i in 0..<image.width * image.height {
            image.pointer.advanced(by: i).pointee = color
        }
    }
    
    func draw(triangle: [Vertex], colorBuffer: ColorImage, depthBuffer: DepthImage) {
        assert(triangle.count == 3)
        #warning("matrix x matrix mul???")
        let a = triangle[0].convertedToScreen(width: colorBuffer.width, height: colorBuffer.height)
        let b = triangle[1].convertedToScreen(width: colorBuffer.width, height: colorBuffer.height)
        let c = triangle[2].convertedToScreen(width: colorBuffer.width, height: colorBuffer.height)

        func setPixel(x: Int, y: Int) {
            guard depthBuffer.contains(x: x, y: y),
                  colorBuffer.contains(x: x, y: y) else {
                print(Self.self, #function, "not contains")
                return
            }
            let triangle = Triangle(a: simd_long2(a.xyz.xy), b: simd_long2(b.xyz.xy), c: simd_long2(c.xyz.xy))
            let ws = triangle.ws(xy: vector_float2(Float(x), Float(y)) + 0.5)
            
            let za = a.xyz.z
            let zb = b.xyz.z
            let zc = c.xyz.z
            let depth: Float = (za * ws.x + zb * ws.y + zc * ws.z)
            guard depth < depthBuffer[x, y] else {
                return
            }
            depthBuffer[x, y] = depth
            
            let ac = a.color
            let bc = b.color
            let cc = c.color
            let color = ac * ws.x + bc * ws.y + cc * ws.z
            
            colorBuffer[x, y] = .init(float3: color)
        }
        
        let sorted = [a, b, c].sorted { $0.xyz.y < $1.xyz.y }.map { simd_long2($0.xyz.xy) }
        let leftVertices = [sorted[0], sorted[1], sorted[2]]
        let rightVertices = [sorted[0], sorted[2]]
        
        for y in stride(from: sorted.first!.y, through: sorted.last!.y, by: 1) {
            var leftX = interpolate(values: leftVertices, t: y)
            var rightX = interpolate(values: rightVertices, t: y)
            if leftX > rightX {
                swap(&leftX, &rightX)
            }
            for x in stride(from: leftX, through: rightX, by: 1) {
                setPixel(x: x, y: y)
            }
//            setPixel(x: leftX, y: y, a: aa(x: leftX, y: y))
//            setPixel(x: rightX, y: y, a: aa(x: rightX, y: y))
        }
    }
    
    func draw(line: [Vertex], colorBuffer: ColorImage, depthBuffer: DepthImage) {
        assert(line.count == 2)
        let a = line[0]
        let b = line[1]
    }
    
    func draw(vertices: [Vertex], colorBuffer: ColorImage, depthBuffer: DepthImage) {
        for vertex in vertices {
            let v = vertex.convertedToScreen(width: colorBuffer.width, height: colorBuffer.height)
            let x = Int(v.xyz.x)
            let y = Int(v.xyz.y)
            colorBuffer[x, y] = Pixel(float3: vertex.color)
        }
    }
    
    func draw(
        triangle3d: Triangle3d,
        with color: Pixel,
        colorBuffer: ColorImage,
        depthBuffer: DepthImage
    ) {
        let triangle = project(triangle3d: triangle3d)
        
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
            guard depthBuffer.contains(x: x, y: y),
                  colorBuffer.contains(x: x, y: y) else {
                print(Self.self, #function, "not contains")
                return
            }
            let ws = triangle.ws(xy: vector_float2(Float(x), Float(y)) + 0.5)
            
            let za = Float(triangle3d.a.z)
            let zb = Float(triangle3d.b.z)
            let zc = Float(triangle3d.c.z)
            let depth: Float = (za * ws.x + zb * ws.y + zc * ws.z)
            guard depth < depthBuffer[x, y] else {
                return
            }
            depthBuffer[x, y] = depth
            
            let ac = vector_float3(1, 0, 0)
            let bc = vector_float3(0, 1, 0)
            let cc = vector_float3(0, 0, 1)
            let color = (ac * ws.x + bc * ws.y + cc * ws.z) * a
            
            colorBuffer[x, y] = .floats(b: color.z, g: color.y, r: color.x, a: 1)
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
        let dx = line.x1 - line.x0
        let dy = line.y1 - line.y0
        let steps = max(abs(dx), abs(dy))
        let xStep = Float(dx) / Float(steps)
        let yStep = Float(dy) / Float(steps)
        
        var x = Float(line.x0)
        var y = Float(line.y0)
        for _ in 0..<steps {
            image[Int(x.rounded()), Int(y.rounded())] = color
            x += xStep
            y += yStep
        }
    }
    
    func draw(triangle: Triangle, with color: Pixel, in image: ColorImage) {
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
            image[x, y] = .floats(b: color.z, g: color.y, r: color.x, a: 1)
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
        if values.count == 3 {
            if t >= values[2].y {
                baseIndex = 2
            } else if t >= values[1].y {
                baseIndex = 1
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
        guard dy != 0 else {
            return start
        }

        let nt = (t - startValue.y)

        let value = start + diff * nt / dy
        return value
    }

    func project(triangle3d: Triangle3d) -> Triangle {
        fatalError()
//        return Triangle(
//            a: project(vector_float3(triangle3d.a)),
//            b: project(vector_float3(triangle3d.b)),
//            c: project(vector_float3(triangle3d.c))
//        )
    }

    func project(line3d: Line3d) -> Line {
        fatalError()
//        let a: simd_long2 = project(vector_float3(line3d.a))
//        let b: simd_long2 = project(vector_float3(line3d.b))
//        return Line(x0: a.x, y0: a.y, x1: b.x, y1: b.y)
    }
    
}

extension simd_float3 {
    var xy: simd_float2 {
        simd_float2(x, y)
    }
}

extension simd_float4 {
    var xyz: simd_float3 {
        simd_float3(x, y, z)
    }
}
