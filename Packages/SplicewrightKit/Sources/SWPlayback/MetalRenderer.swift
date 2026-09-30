import CoreVideo
import Metal
import simd
import SWCore
import SWMedia

/// Per-layer shader parameters. Must match `LayerUniforms` in Shaders.swift.
struct LayerUniforms {
    var row0: SIMD4<Float>
    var row1: SIMD4<Float>
    var sizes: SIMD4<Float>
    var ycbcr: SIMD4<Float>
    var color: SIMD4<Float>
    var tone: SIMD4<Float>
}

/// Must match `OutputUniforms` in Shaders.swift.
struct OutputUniforms {
    var params: SIMD4<Float>
}

/// One decoded source frame to draw, bottom layer first.
struct LayerFrame {
    var pixelBuffer: CVPixelBuffer
    var transform: Affine2D
    var sourceWidth: Double
    var sourceHeight: Double
    var opacity: Double
    /// Used when the frame itself carries no color attachments.
    var fallbackColor: ColorDescription
    /// Interpret Footage override; wins over the frame's attachments.
    var forcedColor: ColorDescription?
}

enum RenderError: Error {
    case noMetalDevice
    case shaderCompilation(String)
    case unsupportedPixelFormat(OSType)
    case textureCreationFailed
}

/// Composites YCbCr source frames into an RGBA half-float output buffer with Metal.
final class MetalRenderer {
    static let shared: MetalRenderer? = try? MetalRenderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let layerPipeline: MTLRenderPipelineState
    private let outputPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private var workingTexture: MTLTexture?
    private let lock = NSLock()

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.noMetalDevice
        }
        self.device = device
        self.queue = queue
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            throw RenderError.shaderCompilation(error.localizedDescription)
        }

        let layer = MTLRenderPipelineDescriptor()
        layer.vertexFunction = library.makeFunction(name: "layerVertex")
        layer.fragmentFunction = library.makeFunction(name: "layerFragment")
        layer.colorAttachments[0].pixelFormat = .rgba16Float
        layer.colorAttachments[0].isBlendingEnabled = true
        layer.colorAttachments[0].rgbBlendOperation = .add
        layer.colorAttachments[0].alphaBlendOperation = .add
        layer.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        layer.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        layer.colorAttachments[0].sourceAlphaBlendFactor = .one
        layer.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        layerPipeline = try device.makeRenderPipelineState(descriptor: layer)

        let output = MTLRenderPipelineDescriptor()
        output.vertexFunction = library.makeFunction(name: "fullScreenVertex")
        output.fragmentFunction = library.makeFunction(name: "outputFragment")
        output.colorAttachments[0].pixelFormat = .rgba16Float
        outputPipeline = try device.makeRenderPipelineState(descriptor: output)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw RenderError.textureCreationFailed
        }
        textureCache = cache
    }

    /// Renders `layers` over black into `output` (a 64RGBAHalf buffer) encoded for `space`.
    func render(layers: [LayerFrame], into output: CVPixelBuffer, space: SequenceColorSpace,
                overlay: OverlayMode = .none) throws {
        lock.lock()
        defer { lock.unlock() }

        let width = CVPixelBufferGetWidth(output)
        let height = CVPixelBufferGetHeight(output)
        var keepAlive: [CVMetalTexture] = []
        let destination = try texture(from: output, plane: 0, format: .rgba16Float, keepAlive: &keepAlive)
        let working = workingTexture(width: width, height: height)
        guard let commandBuffer = queue.makeCommandBuffer() else { throw RenderError.textureCreationFailed }

        let layerPass = MTLRenderPassDescriptor()
        layerPass.colorAttachments[0].texture = working
        layerPass.colorAttachments[0].loadAction = .clear
        layerPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        layerPass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: layerPass) {
            encoder.setRenderPipelineState(layerPipeline)
            for layer in layers {
                guard let format = PlanarFormat(CVPixelBufferGetPixelFormatType(layer.pixelBuffer)) else { continue }
                let luma = try texture(from: layer.pixelBuffer, plane: 0, format: format.lumaFormat, keepAlive: &keepAlive)
                let chroma = try texture(from: layer.pixelBuffer, plane: 1, format: format.chromaFormat,
                                         keepAlive: &keepAlive)
                var uniforms = Self.uniforms(for: layer, format: format, space: space,
                                             renderWidth: width, renderHeight: height)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                encoder.setFragmentTexture(luma, index: 0)
                encoder.setFragmentTexture(chroma, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.endEncoding()
        }

        let outputPass = MTLRenderPassDescriptor()
        outputPass.colorAttachments[0].texture = destination
        outputPass.colorAttachments[0].loadAction = .dontCare
        outputPass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputPass) {
            encoder.setRenderPipelineState(outputPipeline)
            var uniforms = OutputUniforms(params: SIMD4(Float(Self.outputSpaceIndex(space)),
                                                        overlay == .clipping ? 1 : 0, 0, 0))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OutputUniforms>.stride, index: 0)
            encoder.setFragmentTexture(working, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(keepAlive) {}
        ColorAttachments.tag(output, with: space.color)
    }

    // MARK: - Parameters

    static func uniforms(for layer: LayerFrame, format: PlanarFormat, space: SequenceColorSpace,
                         renderWidth: Int, renderHeight: Int) -> LayerUniforms {
        let t = layer.transform
        let height = CVPixelBufferGetHeight(layer.pixelBuffer)
        let color = (layer.forcedColor ?? ColorAttachments.read(layer.pixelBuffer, fallback: layer.fallbackColor))
            .resolved(forHeight: height)
        let isHDRSource = color.transfer == .hlg || color.transfer == .pq
        let toneMap = space == .rec709 && isHDRSource
        // Both HLG and (without mastering metadata) PQ sources are treated as 1000-nit masters.
        let sourcePeak = Float(TransferFunctions.hlgPeakNits / TransferFunctions.referenceWhiteNits)
        return LayerUniforms(
            row0: SIMD4(Float(t.a), Float(t.c), Float(t.tx), 0),
            row1: SIMD4(Float(t.b), Float(t.d), Float(t.ty), 0),
            sizes: SIMD4(Float(layer.sourceWidth), Float(layer.sourceHeight), Float(renderWidth), Float(renderHeight)),
            ycbcr: SIMD4(format.codeScale, format.maxCode, format.isFullRange ? 1 : 0, Float(matrixIndex(color.matrix))),
            color: SIMD4(Float(transferIndex(color.transfer)), Float(primariesIndex(color.primaries)),
                         Float(min(max(layer.opacity, 0), 1)), toneMap ? 1 : 0),
            tone: SIMD4(sourcePeak, 0, 0, 0)
        )
    }

    static func transferIndex(_ transfer: TransferFunction) -> Int {
        switch transfer {
        case .sRGB: return 1
        case .linear: return 2
        case .pq: return 3
        case .hlg: return 4
        case .bt709, .bt2020, .unknown: return 0
        }
    }

    static func primariesIndex(_ primaries: ColorPrimaries) -> Int {
        switch primaries {
        case .bt2020: return 1
        case .displayP3, .dciP3: return 2
        case .bt709, .bt601NTSC, .bt601PAL, .unknown: return 0
        }
    }

    static func matrixIndex(_ matrix: YCbCrMatrix) -> Int {
        switch matrix {
        case .bt601: return 1
        case .bt2020: return 2
        case .bt709, .unknown: return 0
        }
    }

    static func outputSpaceIndex(_ space: SequenceColorSpace) -> Int {
        switch space {
        case .rec709: return 0
        case .rec2100HLG: return 1
        case .rec2100PQ: return 2
        }
    }

    // MARK: - Textures

    private func texture(from buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                         keepAlive: inout [CVMetalTexture]) throws -> MTLTexture {
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format,
                                                               width, height, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw RenderError.textureCreationFailed
        }
        keepAlive.append(cvTexture)
        return texture
    }

    private func workingTexture(width: Int, height: Int) -> MTLTexture? {
        if let existing = workingTexture, existing.width == width, existing.height == height { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        workingTexture = device.makeTexture(descriptor: descriptor)
        return workingTexture
    }
}

/// The bi-planar YCbCr formats the compositor accepts from AVFoundation.
struct PlanarFormat {
    var lumaFormat: MTLPixelFormat
    var chromaFormat: MTLPixelFormat
    /// Multiplies a normalized texel to get its integer code value.
    var codeScale: Float
    var maxCode: Float
    var isFullRange: Bool

    static let accepted: [OSType] = [
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]

    init?(_ type: OSType) {
        switch type {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            self.init(lumaFormat: .r8Unorm, chromaFormat: .rg8Unorm, codeScale: 255, maxCode: 255,
                      isFullRange: type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            // 10-bit codes sit in the top bits of each 16-bit sample.
            self.init(lumaFormat: .r16Unorm, chromaFormat: .rg16Unorm, codeScale: 65535.0 / 64.0, maxCode: 1023,
                      isFullRange: type == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                          || type == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange)
        default:
            return nil
        }
    }

    init(lumaFormat: MTLPixelFormat, chromaFormat: MTLPixelFormat, codeScale: Float, maxCode: Float, isFullRange: Bool) {
        self.lumaFormat = lumaFormat
        self.chromaFormat = chromaFormat
        self.codeScale = codeScale
        self.maxCode = maxCode
        self.isFullRange = isFullRange
    }
}

/// Reads and writes CoreVideo color attachments.
enum ColorAttachments {
    static func read(_ buffer: CVPixelBuffer, fallback: ColorDescription) -> ColorDescription {
        func value(_ key: CFString) -> String? {
            CVBufferCopyAttachment(buffer, key, nil) as? String
        }
        let tagged = ColorDescription(
            primaries: ColorTags.primaries(value(kCVImageBufferColorPrimariesKey)),
            transfer: ColorTags.transfer(value(kCVImageBufferTransferFunctionKey)),
            matrix: ColorTags.matrix(value(kCVImageBufferYCbCrMatrixKey))
        )
        return ColorDescription(
            primaries: tagged.primaries == .unknown ? fallback.primaries : tagged.primaries,
            transfer: tagged.transfer == .unknown ? fallback.transfer : tagged.transfer,
            matrix: tagged.matrix == .unknown ? fallback.matrix : tagged.matrix
        )
    }

    static func tag(_ buffer: CVPixelBuffer, with color: ColorDescription) {
        let tags = OutputColorTags(color)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, tags.primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, tags.transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, tags.matrix, .shouldPropagate)
    }
}

/// CoreVideo tag strings for a sequence's output color space.
struct OutputColorTags {
    var primaries: CFString
    var transfer: CFString
    var matrix: CFString

    init(_ color: ColorDescription) {
        switch color.transfer {
        case .hlg:
            primaries = kCVImageBufferColorPrimaries_ITU_R_2020
            transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        case .pq:
            primaries = kCVImageBufferColorPrimaries_ITU_R_2020
            transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        default:
            primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
            transfer = kCVImageBufferTransferFunction_ITU_R_709_2
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
    }
}
