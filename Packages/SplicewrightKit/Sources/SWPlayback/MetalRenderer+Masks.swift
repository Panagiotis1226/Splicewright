import CoreGraphics
import Foundation
import Metal
import SWCore

/// Mask pipelines, rasterized mask paths (cached while a mask doesn't change), and the
/// frame-sized textures masks are feathered and combined in.
final class MaskResources: @unchecked Sendable {
    private struct RasterKey: Hashable {
        var vertices: [Mask.Vertex]
        var expansion: Double
        var width: Int
        var height: Int
    }

    /// Where a frame's masks are feathered (two blur directions) and combined.
    struct Targets {
        var blurH: MTLTexture
        var blurV: MTLTexture
        var coverage: MTLTexture
    }

    let combineAdd: MTLRenderPipelineState
    let combineSubtract: MTLRenderPipelineState
    let apply: MTLRenderPipelineState
    let mix: MTLRenderPipelineState
    /// Draws a person matte into coverage, placed like the layer (layerVertex).
    let matte: MTLRenderPipelineState
    private let device: MTLDevice
    private let lock = NSLock()
    private var rasters: [RasterKey: MTLTexture] = [:]
    private var order: [RasterKey] = []
    private let capacity = 24
    private var frameTargets: Targets?

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        func pipeline(_ name: String, blend: ((MTLRenderPipelineColorAttachmentDescriptor) -> Void)? = nil) throws
            -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullScreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: name)
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            if let blend {
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                blend(descriptor.colorAttachments[0])
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        // Add: coverage + m × (1 − coverage). Subtract: coverage × (1 − m).
        combineAdd = try pipeline("maskCombineFragment") { attachment in
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceColor
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        combineSubtract = try pipeline("maskCombineFragment") { attachment in
            attachment.sourceRGBBlendFactor = .zero
            attachment.destinationRGBBlendFactor = .oneMinusSourceColor
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        apply = try pipeline("maskApplyFragment")
        mix = try pipeline("maskMixFragment")
        let matteDescriptor = MTLRenderPipelineDescriptor()
        matteDescriptor.vertexFunction = library.makeFunction(name: "layerVertex")
        matteDescriptor.fragmentFunction = library.makeFunction(name: "matteFragment")
        matteDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        matte = try device.makeRenderPipelineState(descriptor: matteDescriptor)
    }

    func targets(width: Int, height: Int) -> Targets? {
        lock.lock()
        defer { lock.unlock() }
        if let frameTargets, frameTargets.coverage.width == width, frameTargets.coverage.height == height {
            return frameTargets
        }
        func make() -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                      height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        guard let blurH = make(), let blurV = make(), let coverage = make() else { return nil }
        frameTargets = Targets(blurH: blurH, blurV: blurV, coverage: coverage)
        return frameTargets
    }

    /// The mask's filled path (grown or shrunk by its expansion), white on black.
    func raster(_ mask: RenderMask, width: Int, height: Int) -> MTLTexture? {
        let key = RasterKey(vertices: mask.vertices, expansion: mask.expansion, width: width, height: height)
        lock.lock()
        defer { lock.unlock() }
        if let cached = rasters[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return cached
        }
        // A new texture each time: one already drawn from may still be in flight.
        guard let texture = makeRaster(mask, width: width, height: height) else { return nil }
        rasters[key] = texture
        order.append(key)
        if order.count > capacity { rasters[order.removeFirst()] = nil }
        return texture
    }

    private func makeRaster(_ mask: RenderMask, width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0, let pixels = Self.rasterize(mask, width: width, height: height) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width)
        }
        return texture
    }

    /// 8-bit coverage, top row first.
    static func rasterize(_ mask: RenderMask, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Render pixels have y down; the bitmap's first row is the top.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setShouldAntialias(true)
            let path = Self.path(mask.vertices)
            context.setFillColor(gray: 1, alpha: 1)
            context.addPath(path)
            context.fillPath()
            if abs(mask.expansion) > 0.01 {
                // Growing strokes the edge in white; shrinking clears a band inside it.
                context.setLineWidth(CGFloat(abs(mask.expansion) * 2))
                context.setLineJoin(.round)
                context.setStrokeColor(gray: mask.expansion > 0 ? 1 : 0, alpha: 1)
                context.addPath(path)
                context.strokePath()
            }
            return true
        }
        return drawn ? pixels : nil
    }

    /// A closed path through the vertices, each segment a cubic through the handles.
    static func path(_ vertices: [Mask.Vertex]) -> CGPath {
        let path = CGMutablePath()
        guard let first = vertices.first else { return path }
        path.move(to: CGPoint(x: first.x, y: first.y))
        for index in vertices.indices {
            let a = vertices[index]
            let b = vertices[(index + 1) % vertices.count]
            path.addCurve(to: CGPoint(x: b.x, y: b.y), control1: CGPoint(x: a.x + a.outX, y: a.y + a.outY),
                          control2: CGPoint(x: b.x + b.inX, y: b.y + b.inY))
        }
        path.closeSubpath()
        return path
    }
}

extension MetalRenderer {
    /// Opacity masks (cut the layer out) and effect masks (the effect only inside them).
    func runMask(_ effect: PixelEffect, on input: MTLTexture, temps: [MTLTexture],
                 commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let free = { (busy: [MTLTexture]) -> MTLTexture in
            temps.first { temp in !busy.contains { $0 === temp } } ?? temps[0]
        }
        switch effect {
        case .mask(let masks):
            let coverage = try maskCoverage(masks, width: input.width, height: input.height, commandBuffer: commandBuffer)
            let output = free([input])
            var uniforms = EffectUniforms(a: .zero)
            try pass(maskResources.apply, into: output, textures: [input, coverage], commandBuffer: commandBuffer,
                     bytes: &uniforms)
            return output
        case .masked(let inner, let masks):
            // The effect runs without touching `input`, which the mix still needs.
            let after = try runEffects(inner, on: input, temps: temps.filter { $0 !== input },
                                       commandBuffer: commandBuffer)
            guard after !== input else { return input }
            // After the inner passes, so a mask inside them is done with the coverage texture.
            let coverage = try maskCoverage(masks, width: input.width, height: input.height, commandBuffer: commandBuffer)
            let output = free([input, after])
            var uniforms = EffectUniforms(a: .zero)
            try pass(maskResources.mix, into: output, textures: [input, after, coverage], commandBuffer: commandBuffer,
                     bytes: &uniforms)
            return output
        case .matte(let matte):
            let coverage = try matteCoverage(matte, width: input.width, height: input.height,
                                             commandBuffer: commandBuffer)
            let output = free([input])
            var uniforms = EffectUniforms(a: .zero)
            try pass(maskResources.apply, into: output, textures: [input, coverage], commandBuffer: commandBuffer,
                     bytes: &uniforms)
            return output
        default:
            return input
        }
    }

    /// A person matte as coverage: drawn where the layer's picture lands, then feathered.
    func matteCoverage(_ matte: PersonMatte, width: Int, height: Int,
                       commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        guard let targets = maskResources.targets(width: width, height: height) else {
            throw RenderError.textureCreationFailed
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: matte.width,
                                                                  height: matte.height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.textureCreationFailed }
        matte.mask.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, matte.width, matte.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: matte.width)
        }
        let t = matte.transform
        var uniforms = LayerUniforms(row0: SIMD4(Float(t.a), Float(t.c), Float(t.tx), 0),
                                     row1: SIMD4(Float(t.b), Float(t.d), Float(t.ty), 0),
                                     sizes: SIMD4(Float(matte.width), Float(matte.height), Float(width), Float(height)),
                                     ycbcr: .zero, color: SIMD4(Float(matte.background), 0, 0, 0), tone: .zero)
        let encoder = try layerEncoder(commandBuffer, target: targets.coverage,
                                       clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        encoder.setRenderPipelineState(maskResources.matte)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        guard matte.feather > 0.25 else { return targets.coverage }
        try blur(targets.coverage, into: targets.blurH, BlurPass(radius: matte.feather, vertical: false),
                 commandBuffer: commandBuffer)
        try blur(targets.blurH, into: targets.blurV, BlurPass(radius: matte.feather, vertical: true),
                 commandBuffer: commandBuffer)
        return targets.blurV
    }

    /// All of a layer's masks folded into one coverage texture (red channel, 0...1). With no
    /// add mask, everything starts covered and subtract masks cut holes in it.
    func maskCoverage(_ masks: [RenderMask], width: Int, height: Int,
                      commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        guard let targets = maskResources.targets(width: width, height: height) else {
            throw RenderError.textureCreationFailed
        }
        let start = masks.contains { $0.mode == .add } ? 0.0 : 1.0
        try layerEncoder(commandBuffer, target: targets.coverage,
                         clear: MTLClearColor(red: start, green: start, blue: start, alpha: start)).endEncoding()
        for mask in masks {
            guard var source = maskResources.raster(mask, width: width, height: height) else { continue }
            if mask.feather > 0.25 {
                try blur(source, into: targets.blurH, BlurPass(radius: mask.feather, vertical: false),
                         commandBuffer: commandBuffer)
                try blur(targets.blurH, into: targets.blurV, BlurPass(radius: mask.feather, vertical: true),
                         commandBuffer: commandBuffer)
                source = targets.blurV
            }
            let encoder = try layerEncoder(commandBuffer, target: targets.coverage, clear: nil)
            encoder.setRenderPipelineState(mask.mode == .add ? maskResources.combineAdd : maskResources.combineSubtract)
            var uniforms = EffectUniforms(a: SIMD4(mask.isInverted ? 1 : 0, Float(min(max(mask.opacity, 0), 1)), 0, 0))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        return targets.coverage
    }
}
