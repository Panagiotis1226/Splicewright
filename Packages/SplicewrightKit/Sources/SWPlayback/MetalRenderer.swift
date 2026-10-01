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
    var crop: SIMD4<Float> = .zero
    var feather: SIMD4<Float> = .zero
    var mirror: SIMD4<Float> = .zero
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
    var geometry: LayerGeometry = .none
}

/// Must match `TransitionUniforms` in Shaders.swift.
struct TransitionUniforms {
    /// Kind index, progress (0...1), unused, unused.
    var params: SIMD4<Float>
}

/// A title to draw over the whole frame.
struct TitleFrame {
    var spec: TitleSpec
    var opacity: Double
    /// Frame-sized texture → render pixels (identity unless the title has motion).
    var transform: Affine2D = .identity
    var geometry: LayerGeometry = .none
}

/// One layer's pixels: a decoded video frame or a rasterized title.
enum LayerSource {
    case video(LayerFrame)
    case title(TitleFrame)
}

/// The two sides of a transition on one track. Either side may be missing (a fade).
struct TransitionFrame {
    var outgoing: LayerSource?
    var incoming: LayerSource?
    var kind: TransitionKind
    var progress: Double
    var outgoingEffects: [PixelEffect] = []
    var incomingEffects: [PixelEffect] = []
}

/// What to draw, bottom first.
enum RenderItem {
    case layer(LayerSource)
    /// A layer drawn off to the side, run through blur/sharpen/shadow, then composited.
    case effected(LayerSource, [PixelEffect])
    case transition(TransitionFrame)
    case adjustment(AdjustmentFrame)
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
    let layerPipeline: MTLRenderPipelineState
    private let outputPipeline: MTLRenderPipelineState
    let transitionPipeline: MTLRenderPipelineState
    private let titlePipeline: MTLRenderPipelineState
    let blurPipeline: MTLRenderPipelineState
    let sharpenPipeline: MTLRenderPipelineState
    let shadowPipeline: MTLRenderPipelineState
    let geometryPipeline: MTLRenderPipelineState
    let overPipeline: MTLRenderPipelineState
    /// Mixes a texture into the target by the blend color (adjustment layers replace what's below).
    let replacePipeline: MTLRenderPipelineState
    private let titles: TitleRasterizer
    private let textureCache: CVMetalTextureCache
    private var workingTexture: MTLTexture?
    /// Each side of a transition is drawn here first (transparent where it doesn't cover).
    private var scratchTextures: [MTLTexture] = []
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
        layer.fragmentFunction = library.makeFunction(name: "titleFragment")
        titlePipeline = try device.makeRenderPipelineState(descriptor: layer)
        titles = TitleRasterizer(device: device)

        let output = MTLRenderPipelineDescriptor()
        output.vertexFunction = library.makeFunction(name: "fullScreenVertex")
        output.fragmentFunction = library.makeFunction(name: "outputFragment")
        output.colorAttachments[0].pixelFormat = .rgba16Float
        outputPipeline = try device.makeRenderPipelineState(descriptor: output)

        // Transition mixes are premultiplied, composited over the layers below.
        let mix = MTLRenderPipelineDescriptor()
        mix.vertexFunction = library.makeFunction(name: "fullScreenVertex")
        mix.fragmentFunction = library.makeFunction(name: "transitionFragment")
        mix.colorAttachments[0].pixelFormat = .rgba16Float
        mix.colorAttachments[0].isBlendingEnabled = true
        mix.colorAttachments[0].sourceRGBBlendFactor = .one
        mix.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        mix.colorAttachments[0].sourceAlphaBlendFactor = .one
        mix.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        transitionPipeline = try device.makeRenderPipelineState(descriptor: mix)
        // A premultiplied texture over the target (effected layers).
        mix.fragmentFunction = library.makeFunction(name: "overFragment")
        overPipeline = try device.makeRenderPipelineState(descriptor: mix)
        // target × (1 − opacity) + texture × opacity, with the opacity as the blend color.
        mix.colorAttachments[0].sourceRGBBlendFactor = .blendColor
        mix.colorAttachments[0].destinationRGBBlendFactor = .oneMinusBlendColor
        mix.colorAttachments[0].sourceAlphaBlendFactor = .blendAlpha
        mix.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusBlendAlpha
        replacePipeline = try device.makeRenderPipelineState(descriptor: mix)

        // Effect passes write every pixel of their target; no blending.
        func pass(_ name: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullScreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: name)
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        blurPipeline = try pass("blurFragment")
        sharpenPipeline = try pass("sharpenFragment")
        shadowPipeline = try pass("shadowFragment")
        geometryPipeline = try pass("geometryFragment")

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw RenderError.textureCreationFailed
        }
        textureCache = cache
    }

    /// Renders `layers` over black into `output` (a 64RGBAHalf buffer) encoded for `space`.
    func render(layers: [LayerFrame], into output: CVPixelBuffer, space: SequenceColorSpace,
                overlay: OverlayMode = .none) throws {
        try render(items: layers.map { .layer(.video($0)) }, into: output, space: space, overlay: overlay)
    }

    /// Renders `items` over black into `output` (a 64RGBAHalf buffer) encoded for `space`.
    func render(items: [RenderItem], into output: CVPixelBuffer, space: SequenceColorSpace,
                overlay: OverlayMode = .none) throws {
        lock.lock()
        defer { lock.unlock() }

        let width = CVPixelBufferGetWidth(output)
        let height = CVPixelBufferGetHeight(output)
        var keepAlive: [CVMetalTexture] = []
        let destination = try texture(from: output, plane: 0, format: .rgba16Float, keepAlive: &keepAlive)
        guard let working = workingTexture(width: width, height: height),
              let commandBuffer = queue.makeCommandBuffer() else { throw RenderError.textureCreationFailed }

        var encoder = try layerEncoder(commandBuffer, target: working, clear: MTLClearColor(red: 0, green: 0, blue: 0,
                                                                                             alpha: 1))
        for item in items {
            switch item {
            case .layer(let layer):
                try draw(layer, with: encoder, space: space, size: (width, height), keepAlive: &keepAlive)
            case .effected(let layer, let effects):
                encoder.endEncoding()
                let textures = try scratch(width: width, height: height)
                let temps = Array(textures[2...])
                try drawAside(layer, into: temps[0], DrawContext(commandBuffer: commandBuffer, space: space,
                                                                 size: (width, height)), keepAlive: &keepAlive)
                let result = try runEffects(effects, on: temps[0], temps: temps, commandBuffer: commandBuffer)
                encoder = try layerEncoder(commandBuffer, target: working, clear: nil)
                composite(result, opacity: 1, with: encoder)
            case .adjustment(let adjustment):
                encoder.endEncoding()
                try applyAdjustment(adjustment, to: working, commandBuffer: commandBuffer, size: (width, height))
                encoder = try layerEncoder(commandBuffer, target: working, clear: nil)
            case .transition(let transition):
                encoder.endEncoding()
                try drawTransition(transition, onto: working,
                                   DrawContext(commandBuffer: commandBuffer, space: space, size: (width, height)),
                                   keepAlive: &keepAlive)
                encoder = try layerEncoder(commandBuffer, target: working, clear: nil)
            }
        }
        encoder.endEncoding()

        let outputPass = MTLRenderPassDescriptor()
        outputPass.colorAttachments[0].texture = destination
        outputPass.colorAttachments[0].loadAction = .dontCare
        outputPass.colorAttachments[0].storeAction = .store
        if let outputEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputPass) {
            outputEncoder.setRenderPipelineState(outputPipeline)
            var uniforms = OutputUniforms(params: SIMD4(Float(Self.outputSpaceIndex(space)),
                                                        overlay == .clipping ? 1 : 0, 0, 0))
            outputEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<OutputUniforms>.stride, index: 0)
            outputEncoder.setFragmentTexture(working, index: 0)
            outputEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            outputEncoder.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(keepAlive) {}
        ColorAttachments.tag(output, with: space.color)
    }

    /// A layer-pipeline encoder on `target`, cleared to `clear` (or keeping its contents if nil).
    func layerEncoder(_ commandBuffer: MTLCommandBuffer, target: MTLTexture,
                      clear: MTLClearColor?) throws -> MTLRenderCommandEncoder {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear == nil ? .load : .clear
        if let clear { pass.colorAttachments[0].clearColor = clear }
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.textureCreationFailed
        }
        encoder.setRenderPipelineState(layerPipeline)
        return encoder
    }

    func draw(_ source: LayerSource, with encoder: MTLRenderCommandEncoder, space: SequenceColorSpace,
              size: (width: Int, height: Int), keepAlive: inout [CVMetalTexture]) throws {
        let (width, height) = size
        guard case .video(let layer) = source else {
            if case .title(let title) = source { drawTitle(title, with: encoder, width: width, height: height) }
            return
        }
        guard let format = PlanarFormat(CVPixelBufferGetPixelFormatType(layer.pixelBuffer)) else { return }
        let luma = try texture(from: layer.pixelBuffer, plane: 0, format: format.lumaFormat, keepAlive: &keepAlive)
        let chroma = try texture(from: layer.pixelBuffer, plane: 1, format: format.chromaFormat, keepAlive: &keepAlive)
        var uniforms = Self.uniforms(for: layer, format: format, space: space, renderWidth: width, renderHeight: height)
        if !layer.geometry.isIdentity {
            // Feather is in render pixels; the shader wants it in the layer's own uv.
            let t = layer.transform
            let drawnWidth = max(1, layer.sourceWidth * hypot(t.a, t.b))
            let drawnHeight = max(1, layer.sourceHeight * hypot(t.c, t.d))
            uniforms.apply(layer.geometry, featherUV: SIMD2(Float(layer.geometry.featherPixels / drawnWidth),
                                                            Float(layer.geometry.featherPixels / drawnHeight)))
        }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setFragmentTexture(luma, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Titles are frame-sized sRGB textures; white lands at reference white in every space.
    private func drawTitle(_ title: TitleFrame, with encoder: MTLRenderCommandEncoder, width: Int, height: Int) {
        guard let texture = titles.texture(for: title.spec, width: width, height: height) else { return }
        let size = SIMD4(Float(width), Float(height), Float(width), Float(height))
        let t = title.transform
        var uniforms = LayerUniforms(row0: SIMD4(Float(t.a), Float(t.c), Float(t.tx), 0),
                                     row1: SIMD4(Float(t.b), Float(t.d), Float(t.ty), 0), sizes: size, ycbcr: .zero,
                                     color: SIMD4(0, 0, Float(min(max(title.opacity, 0), 1)), 0), tone: .zero)
        uniforms.apply(title.geometry, featherUV: SIMD2(Float(title.geometry.featherPixels) / Float(width),
                                                        Float(title.geometry.featherPixels) / Float(height)))
        encoder.setRenderPipelineState(titlePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.setRenderPipelineState(layerPipeline)
    }

    static func transitionIndex(_ kind: TransitionKind) -> Int {
        switch kind {
        case .crossDissolve, .constantPower, .constantGain: return 0
        case .dipToBlack: return 1
        case .dipToWhite: return 2
        case .filmDissolve: return 3
        case .wipeRight: return 4
        case .wipeLeft: return 5
        case .wipeDown: return 6
        case .wipeUp: return 7
        }
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
        workingTexture = makeRenderTexture(width: width, height: height)
        return workingTexture
    }

    /// Six frame-sized textures: two transition sides, then four for effect passes.
    func scratch(width: Int, height: Int) throws -> [MTLTexture] {
        if scratchTextures.count == 6, scratchTextures[0].width == width, scratchTextures[0].height == height {
            return scratchTextures
        }
        let textures = (0..<6).compactMap { _ in makeRenderTexture(width: width, height: height) }
        guard textures.count == 6 else { throw RenderError.textureCreationFailed }
        scratchTextures = textures
        return textures
    }

    private func makeRenderTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
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
