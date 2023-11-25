import CoreVideo
import Metal
import MetalPerformanceShaders

class MTLContext {
    static let shared = MTLContext()

    let device = MTLCreateSystemDefaultDevice()!
    lazy var library = device.makeDefaultLibrary()!
    lazy var queue = device.makeCommandQueue()!

    func makeComputePipelineState(functionName: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: functionName) else {
            throw Error.noFunction(name: functionName)
        }
        return try device.makeComputePipelineState(function: function)
    }

    func makeRenderPipelineState(
        pixelFormat: MTLPixelFormat,
        vertexFunction: String,
        fragmentFunction: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor(
            vertexFunction: vertexFunction,
            fragmentFunction: fragmentFunction,
            pixelFormat: pixelFormat,
            library: library
        )
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func makeRenderPipelineState(
        pixelFormat: MTLPixelFormat,
        fragmentFunction: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor(
            vertexFunction: "passthroughVertexFunction",
            fragmentFunction: fragmentFunction,
            pixelFormat: pixelFormat,
            library: library
        )
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    @discardableResult
    func schedule(_ work: (_ commandBuffer: MTLCommandBuffer) -> Void) -> MTLCommandBuffer? {
        guard let commandBuffer = queue.makeCommandBuffer() else {
            print(Self.self, #function, "no command buffer")
            return nil
        }
        work(commandBuffer)
        commandBuffer.commit()
        return commandBuffer
    }

    @discardableResult
    func scheduleAndWait<T>(_ work: (_ commandBuffer: MTLCommandBuffer) -> T?) -> T? {
        guard let commandBuffer = queue.makeCommandBuffer() else {
            print(Self.self, #function, "no command buffer")
            return nil
        }
        let result = work(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return result
    }
}

extension MTLContext {
    enum Error: Swift.Error {
        case noFunction(name: String)
    }
}

extension MTLRenderPipelineDescriptor {
    convenience init(
        vertexFunction: String,
        fragmentFunction: String,
        pixelFormat: MTLPixelFormat,
        library: MTLLibrary
    ) {
        self.init()
        colorAttachments[0].pixelFormat = pixelFormat
        colorAttachments[0].isBlendingEnabled = true
        colorAttachments[0].rgbBlendOperation = .add
        colorAttachments[0].alphaBlendOperation = .add
        colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.vertexFunction = library.makeFunction(name: vertexFunction)!
        self.fragmentFunction = library.makeFunction(name: fragmentFunction)!
    }
}

public extension MTLTexture {
    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    var size: MTLSize {
        MTLSize(width: width, height: height, depth: depth)
    }

    var descriptor: MTLTextureDescriptor {
        let output = MTLTextureDescriptor()

        output.width = width
        output.height = height
        output.depth = depth
        output.arrayLength = arrayLength
        output.storageMode = storageMode
        output.cpuCacheMode = cpuCacheMode
        output.usage = usage
        output.textureType = textureType
        output.sampleCount = sampleCount
        output.mipmapLevelCount = mipmapLevelCount
        output.pixelFormat = pixelFormat
        output.allowGPUOptimizedContents = allowGPUOptimizedContents

        return output
    }

    var temporaryTextureDescriptor: MTLTextureDescriptor {
        let descriptor = descriptor
        descriptor.storageMode = .private
        return descriptor
    }

    func allChannelsSwizzled(as swizzle: MTLTextureSwizzle) -> MTLTexture? {
        makeTextureView(
            pixelFormat: pixelFormat,
            textureType: textureType,
            levels: 0 ..< 1,
            slices: 0 ..< 1,
            swizzle: MTLTextureSwizzleChannels(
                red: swizzle, green: swizzle, blue: swizzle, alpha: swizzle
            )
        )
    }
}

public extension MTLBlitCommandEncoder {
    func fillWith0(_ buffer: MTLBuffer) {
        fill(buffer: buffer, range: 0 ..< buffer.length, value: 0)
    }
}

public extension MTLRenderCommandEncoder {
    func set<T>(vertexValue: inout T, index: Int) {
        setVertexBytes(&vertexValue, length: MemoryLayout<T>.stride, index: index)
    }

    func set<T>(fragmentValue: inout T, index: Int) {
        setFragmentBytes(&fragmentValue, length: MemoryLayout<T>.stride, index: index)
    }
}

public extension MTLTextureDescriptor {
    static func texture2DDescriptor(
        pixelFormat: MTLPixelFormat,
        size: CGSize,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget]
    ) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = usage
        return descriptor
    }
}

public extension MPSTemporaryImage {
    convenience init(
        commandBuffer: MTLCommandBuffer,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        size: CGSize
    ) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, size: size)
        descriptor.storageMode = .private
        self.init(commandBuffer: commandBuffer, textureDescriptor: descriptor)
    }
}

public extension MTLComputeCommandEncoder {
    func set<T>(value: inout T, index: Int) {
        setBytes(&value, length: MemoryLayout<T>.stride, index: index)
    }

    func dispatch2d(state: MTLComputePipelineState, size: MTLSize) {
        if device.supports(feature: .nonUniformThreadgroups) {
            dispatch2d(state: state, exactly: size)
        } else {
            dispatch2d(state: state, covering: size)
        }
    }

    func dispatch2d(
        state: MTLComputePipelineState,
        covering size: MTLSize,
        threadgroupSize: MTLSize? = nil
    ) {
        let tgSize = threadgroupSize ?? state.max2dThreadgroupSize

        let count = MTLSize(
            width: (size.width + tgSize.width - 1) / tgSize.width,
            height: (size.height + tgSize.height - 1) / tgSize.height,
            depth: 1
        )

        setComputePipelineState(state)
        dispatchThreadgroups(count, threadsPerThreadgroup: tgSize)
    }

    func dispatch2d(
        state: MTLComputePipelineState,
        exactly size: MTLSize,
        threadgroupSize: MTLSize? = nil
    ) {
        let tgSize = threadgroupSize ?? state.max2dThreadgroupSize

        setComputePipelineState(state)
        dispatchThreads(size, threadsPerThreadgroup: tgSize)
    }

    func set(textures: [MTLTexture?]) {
        setTextures(textures, range: textures.indices)
    }
}

public enum MTLFeature {
    case nonUniformThreadgroups
    case readWriteTextures(MTLPixelFormat)
}

public enum MTLDeviceError: Swift.Error {
    case noTexture
}

public extension MTLDevice {
    func supports(feature: MTLFeature) -> Bool {
        switch feature {
        case .nonUniformThreadgroups:
            #if targetEnvironment(macCatalyst)
                return supportsFamily(.common3)
            #elseif os(iOS)
                return supportsFeatureSet(.iOS_GPUFamily4_v1)
            #elseif os(macOS)
                return supportsFeatureSet(.macOS_GPUFamily1_v3)
            #elseif os(visionOS)
                return true
            #endif

        case let .readWriteTextures(pixelFormat):
            let tierOneSupportedPixelFormats: Set<MTLPixelFormat> = [
                .r32Float, .r32Uint, .r32Sint,
            ]
            let tierTwoSupportedPixelFormats: Set<MTLPixelFormat> = tierOneSupportedPixelFormats.union([
                .rgba32Float, .rgba32Uint, .rgba32Sint, .rgba16Float,
                .rgba16Uint, .rgba16Sint, .rgba8Unorm, .rgba8Uint,
                .rgba8Sint, .r16Float, .r16Uint, .r16Sint,
                .r8Unorm, .r8Uint, .r8Sint,
            ])

            switch readWriteTextureSupport {
            case .tier1: return tierOneSupportedPixelFormats.contains(pixelFormat)
            case .tier2: return tierTwoSupportedPixelFormats.contains(pixelFormat)
            case .tierNone: return false
            @unknown default: return false
            }
        }
    }

    func makeTextureThrows(descriptor: MTLTextureDescriptor) throws -> MTLTexture {
        guard let texture = makeTexture(descriptor: descriptor) else {
            throw MTLDeviceError.noTexture
        }
        return texture
    }

    func makeBufferBackedTexture(descriptor: MTLTextureDescriptor) -> MTLTexture? {
        guard let pixelSizeInBytes = descriptor.pixelFormat.size else {
            return nil
        }
        let height = descriptor.height
        let bytesPerRow = (descriptor.width * pixelSizeInBytes).aligned(
            in: minimumTextureBufferAlignment(for: descriptor.pixelFormat)
        )
        let length = height * bytesPerRow
        let storageMode: MTLResourceOptions = {
            switch descriptor.storageMode {
            case .private:
                return .storageModePrivate
            case .shared:
                return .storageModeShared
            case .memoryless:
                return .storageModeMemoryless
            @unknown default:
                return .storageModeShared
            }
        }()
        guard let buffer = makeBuffer(length: length, options: storageMode) else {
            return nil
        }

        guard let texture = buffer.makeTexture(
            descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow
        ) else {
            return nil
        }

        return texture
    }

    func makePixelBufferBackedTexture(
        descriptor: MTLTextureDescriptor
    ) -> (MTLTexture, CVPixelBuffer)? {
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue,
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            descriptor.width,
            descriptor.height,
            descriptor.pixelFormat.compatibleCVPixelFormat,
            attributes,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess,
              let pixelBuffer,
              let texture = makePixelBufferBackedTexture(
                  descriptor: descriptor,
                  pixelBuffer: pixelBuffer
              )
        else {
            return nil
        }
        return (texture, pixelBuffer)
    }

    func makePixelBufferBackedTexture(
        descriptor: MTLTextureDescriptor,
        pixelBuffer: CVPixelBuffer
    ) -> MTLTexture? {
        guard let ioSurface = CVPixelBufferGetIOSurface(pixelBuffer),
              let texture = makeTexture(
                  descriptor: descriptor,
                  iosurface: ioSurface.takeUnretainedValue(),
                  plane: 0
              )
        else {
            return nil
        }
        return texture
    }
}

public extension MTLComputePipelineState {
    var max2dThreadgroupSize: MTLSize {
        let width = threadExecutionWidth
        let height = maxTotalThreadsPerThreadgroup / width

        return MTLSize(width: width, height: height, depth: 1)
    }
}

extension MTLSize: Equatable {
    public static func == (_ lhs: MTLSize, _ rhs: MTLSize) -> Bool {
        lhs.width == rhs.width &&
            lhs.height == rhs.height &&
            lhs.depth == rhs.depth
    }
}

public extension MTLCommandBuffer {
    var gpuExecutionTime: CFTimeInterval {
        gpuEndTime - gpuStartTime
    }

    var kernelExecutionTime: CFTimeInterval {
        kernelEndTime - kernelStartTime
    }

    func compute(_ work: (_ encoder: MTLComputeCommandEncoder) -> Void) {
        guard let encoder = makeComputeCommandEncoder() else {
            print(Self.self, #function, "no compute encoder")
            return
        }
        work(encoder)
        encoder.endEncoding()
    }

    func blit(_ work: (_ encoder: MTLBlitCommandEncoder) -> Void) {
        guard let encoder = makeBlitCommandEncoder() else {
            print(Self.self, #function, "no blit encoder")
            return
        }
        work(encoder)
        encoder.endEncoding()
    }

    func copy(from sourceTexture: MTLTexture, to destinationTexture: MTLTexture) {
        blit { encoder in
            encoder.copy(from: sourceTexture, to: destinationTexture)
        }
    }

    func render(descriptor: MTLRenderPassDescriptor, _ work: (_ encoder: MTLRenderCommandEncoder) -> Void) {
        guard let encoder = makeRenderCommandEncoder(descriptor: descriptor) else {
            print(Self.self, #function, "no render encoder")
            return
        }
        work(encoder)
        encoder.endEncoding()
    }

    func render(to texture: MTLTexture, _ work: (_ encoder: MTLRenderCommandEncoder) -> Void) {
        let descriptor = MTLRenderPassDescriptor(texture: texture)
        render(descriptor: descriptor, work)
    }

    func clear(texture: MTLTexture, color: MTLClearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)) {
        let descriptor = MTLRenderPassDescriptor()
        let attachDescriptor = MTLRenderPassColorAttachmentDescriptor()
        attachDescriptor.texture = texture
        attachDescriptor.loadAction = .clear
        attachDescriptor.storeAction = .store
        attachDescriptor.clearColor = color

        descriptor.colorAttachments[0] = attachDescriptor

        render(descriptor: descriptor) { _ in }
    }
}

public extension MPSScaleTransform {
    init(from fromSize: CGSize, to toSize: CGSize) {
        self.init(
            scaleX: toSize.width / fromSize.width,
            scaleY: toSize.height / fromSize.height,
            translateX: 0,
            translateY: 0
        )
    }
}

public extension MTLCommandBuffer {
    func resize(
        texture: MTLTexture,
        toTexture: MTLTexture,
        scaleTransformP: UnsafePointer<MPSScaleTransform>
    ) {
        let resizeKernel = MPSImageBilinearScale(device: device)
        resizeKernel.scaleTransform = scaleTransformP
        resizeKernel.encode(
            commandBuffer: self,
            sourceTexture: texture,
            destinationTexture: toTexture
        )
    }

    func resize(texture: MTLTexture, toSize: MTLSize) -> (MTLTexture, (() -> Void)?) {
        guard texture.size != toSize else {
            return (texture, nil)
        }
        let descriptor = texture.temporaryTextureDescriptor
        descriptor.width = toSize.width
        descriptor.height = toSize.height
        descriptor.depth = toSize.depth

        let outputImage = MPSTemporaryImage(
            commandBuffer: self, textureDescriptor: descriptor
        )
        var scale = MPSScaleTransform(from: texture.cgSize, to: outputImage.texture.cgSize)
        resize(texture: texture, toTexture: outputImage.texture, scaleTransformP: &scale)
        return (outputImage.texture, { outputImage.readCount = 0 })
    }
}

extension MTLRenderPassDescriptor {
    convenience init(texture: MTLTexture) {
        self.init()

        let descriptor = MTLRenderPassColorAttachmentDescriptor()
        descriptor.texture = texture
        descriptor.loadAction = .clear
        descriptor.storeAction = .store
        descriptor.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        colorAttachments[0] = descriptor
    }
}

public extension MTLPixelFormat {
    var components: Int? {
        switch self {
        case .a8Unorm,
             .r8Unorm,
             .r8Snorm,
             .r8Uint,
             .r8Sint,
             .stencil8,
             .r8Unorm_srgb,
             .r16Unorm,
             .r16Snorm,
             .r16Uint,
             .r16Sint,
             .r16Float,
             .r32Uint,
             .r32Sint,
             .r32Float:
            return 1
        case .rg8Unorm,
             .rg8Unorm_srgb,
             .rg8Snorm,
             .rg8Uint,
             .rg8Sint,
             .rg16Unorm,
             .rg16Snorm,
             .rg16Uint,
             .rg16Sint,
             .rg16Float,
             .rg32Uint,
             .rg32Sint,
             .rg32Float:
            return 2
        case .rgba8Unorm,
             .rgba8Unorm_srgb,
             .rgba8Snorm,
             .rgba8Uint,
             .rgba8Sint,
             .bgra8Unorm,
             .bgra8Unorm_srgb,
             .rgba16Unorm,
             .rgba16Snorm,
             .rgba16Uint,
             .rgba16Sint,
             .rgba16Float,
             .rgba32Uint,
             .rgba32Sint,
             .rgba32Float:
            return 4
        default:
            return nil
        }
    }

    var size: Int? {
        switch self {
        case .a8Unorm, .r8Unorm, .r8Snorm,
             .r8Uint, .r8Sint, .stencil8, .r8Unorm_srgb: return 1
        case .r16Unorm, .r16Snorm, .r16Uint,
             .r16Sint, .r16Float, .rg8Unorm,
             .rg8Snorm, .rg8Uint, .rg8Sint,
             .depth16Unorm, .rg8Unorm_srgb: return 2
        case .r32Uint, .r32Sint, .r32Float,
             .rg16Unorm, .rg16Snorm, .rg16Uint,
             .rg16Sint, .rg16Float, .rgba8Unorm,
             .rgba8Unorm_srgb, .rgba8Snorm, .rgba8Uint,
             .rgba8Sint, .bgra8Unorm, .bgra8Unorm_srgb,
             .rgb10a2Unorm, .rgb10a2Uint, .rg11b10Float,
             .rgb9e5Float, .bgr10a2Unorm, .gbgr422,
             .bgrg422, .depth32Float, .depth24Unorm_stencil8,
             .x24_stencil8, .bgr10_xr_srgb, .bgr10_xr: return 4
        case .rg32Uint, .rg32Sint, .rg32Float,
             .rgba16Unorm, .rgba16Snorm, .rgba16Uint,
             .rgba16Sint, .rgba16Float, .bc1_rgba,
             .bc1_rgba_srgb, .depth32Float_stencil8, .x32_stencil8,
             .bgra10_xr, .bgra10_xr_srgb: return 8
        case .rgba32Uint, .rgba32Sint, .rgba32Float,
             .bc2_rgba, .bc2_rgba_srgb, .bc3_rgba,
             .bc3_rgba_srgb: return 16
        default:
            // TODO: Finish bc4-bc7
            return nil
        }
    }
}

public extension MTLPixelFormat {
    var compatibleCVPixelFormat: OSType {
        switch self {
        case .r8Unorm, .r8Unorm_srgb: return kCVPixelFormatType_OneComponent8
        case .r16Float: return kCVPixelFormatType_OneComponent16Half
        case .r32Float: return kCVPixelFormatType_OneComponent32Float

        case .rg8Unorm, .rg8Unorm_srgb: return kCVPixelFormatType_TwoComponent8
        case .rg16Float: return kCVPixelFormatType_TwoComponent16Half
        case .rg32Float: return kCVPixelFormatType_TwoComponent32Float

        case .bgra8Unorm, .bgra8Unorm_srgb: return kCVPixelFormatType_32BGRA
        case .rgba8Unorm, .rgba8Unorm_srgb: return kCVPixelFormatType_32RGBA
        case .rgba16Float: return kCVPixelFormatType_64RGBAHalf
        case .rgba32Float: return kCVPixelFormatType_128RGBAFloat

        case .depth32Float: return kCVPixelFormatType_DepthFloat32
        default: return 0
        }
    }
}

public extension Int {
    fileprivate static let pageSize = Int(getpagesize())

    func aligned(in align: Int) -> Int {
        Int(ceil(Double(self) / Double(align))) * align
    }

    var pageAligned: Int {
        aligned(in: .pageSize)
    }
}
