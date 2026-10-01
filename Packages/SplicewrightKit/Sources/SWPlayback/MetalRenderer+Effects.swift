import CoreVideo
import Metal
import simd
import SWCore

/// Must match `EffectUniforms` in Shaders.swift.
struct EffectUniforms {
    var a: SIMD4<Float>
    var b: SIMD4<Float> = .zero
}

/// Crop sides as fractions of the layer (0...1).
struct CropInsets: Equatable {
    var left = 0.0
    var top = 0.0
    var right = 0.0
    var bottom = 0.0
}

/// Crop, Flip and Mirror, applied while a layer is drawn.
struct LayerGeometry: Equatable {
    var crop = CropInsets()
    /// Edge feather in render pixels.
    var featherPixels: Double = 0
    var flipHorizontal = false
    var flipVertical = false
    /// Reflection center (fraction of the width) and angle (radians).
    var mirror: (center: Double, angle: Double)?

    static let none = LayerGeometry()

    var isIdentity: Bool { self == .none }

    static func == (lhs: LayerGeometry, rhs: LayerGeometry) -> Bool {
        lhs.crop == rhs.crop && lhs.featherPixels == rhs.featherPixels && lhs.flipHorizontal == rhs.flipHorizontal
            && lhs.flipVertical == rhs.flipVertical && lhs.mirror?.center == rhs.mirror?.center
            && lhs.mirror?.angle == rhs.mirror?.angle
    }
}

/// An effect that needs its own passes over a layer's pixels, in render pixels.
enum PixelEffect {
    case blur(radius: Double)
    case sharpen(amount: Double)
    /// Offset in render pixels (y down), softness as a blur radius.
    case shadow(opacity: Double, offsetX: Double, offsetY: Double, softness: Double)
}

/// An adjustment layer: its effects applied to everything composited so far.
struct AdjustmentFrame {
    var geometry: LayerGeometry
    var effects: [PixelEffect]
    var opacity: Double
}

/// Must match `OutputUniforms` in Shaders.swift.
struct OutputUniforms {
    var params: SIMD4<Float>
}

extension LayerUniforms {
    /// Applies Crop, Flip and Mirror (`feather` is in uv units of the drawn layer).
    mutating func apply(_ geometry: LayerGeometry, featherUV: SIMD2<Float>) {
        crop = SIMD4(Float(geometry.crop.left), Float(geometry.crop.top), Float(geometry.crop.right),
                     Float(geometry.crop.bottom))
        feather = SIMD4(featherUV.x, featherUV.y, geometry.flipHorizontal ? 1 : 0, geometry.flipVertical ? 1 : 0)
        if let mirror = geometry.mirror {
            self.mirror = SIMD4(1, Float(mirror.center), Float(mirror.angle), 0)
        } else {
            self.mirror = .zero
        }
    }
}

/// Effect passes: blur, sharpen, drop shadow, adjustment layers, and transitions through them.
extension MetalRenderer {
    /// What every pass of one frame shares.
    struct DrawContext {
        var commandBuffer: MTLCommandBuffer
        var space: SequenceColorSpace
        var size: (width: Int, height: Int)
    }

    /// Adjustment layer: copies what's composited so far, runs the effects on it, and blends
    /// the result back over it at the layer's opacity.
    func applyAdjustment(_ adjustment: AdjustmentFrame, to working: MTLTexture, commandBuffer: MTLCommandBuffer,
                         size: (width: Int, height: Int)) throws {
        let (width, height) = size
        let temps = Array(try scratch(width: width, height: height)[2...])
        try copy(working, to: temps[0], commandBuffer: commandBuffer)
        var current = temps[0]
        if !adjustment.geometry.isIdentity {
            var uniforms = LayerUniforms(row0: .zero, row1: .zero, sizes: SIMD4(0, 0, Float(width), Float(height)),
                                         ycbcr: .zero, color: .zero, tone: .zero)
            let feather = Float(adjustment.geometry.featherPixels)
            uniforms.apply(adjustment.geometry, featherUV: SIMD2(feather / Float(width), feather / Float(height)))
            try pass(geometryPipeline, into: temps[1], textures: [current], commandBuffer: commandBuffer, bytes: &uniforms)
            current = temps[1]
        }
        current = try runEffects(adjustment.effects, on: current, temps: temps, commandBuffer: commandBuffer)
        // The adjusted picture replaces what's below (a crop leaves black, as in Premiere),
        // mixed by the layer's opacity.
        let encoder = try layerEncoder(commandBuffer, target: working, clear: nil)
        let opacity = Float(min(max(adjustment.opacity, 0), 1))
        encoder.setRenderPipelineState(replacePipeline)
        encoder.setBlendColor(red: opacity, green: opacity, blue: opacity, alpha: opacity)
        var uniforms = EffectUniforms(a: SIMD4(1, 0, 0, 0))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        encoder.setFragmentTexture(current, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Draws each side into its own texture (through its effects), then mixes them over `working`.
    func drawTransition(_ transition: TransitionFrame, onto working: MTLTexture, _ context: DrawContext,
                        keepAlive: inout [CVMetalTexture]) throws {
        let commandBuffer = context.commandBuffer
        let scratch = try scratch(width: context.size.width, height: context.size.height)
        let temps = Array(scratch[2...])
        let sides = [(transition.outgoing, transition.outgoingEffects), (transition.incoming, transition.incomingEffects)]
        for ((side, effects), target) in zip(sides, scratch) {
            if let side {
                try drawAside(side, into: target, context, keepAlive: &keepAlive)
            } else {
                let transparent = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                try layerEncoder(commandBuffer, target: target, clear: transparent).endEncoding()
            }
            if !effects.isEmpty {
                let result = try runEffects(effects, on: target, temps: temps, commandBuffer: commandBuffer)
                if result !== target { try copy(result, to: target, commandBuffer: commandBuffer) }
            }
        }
        let encoder = try layerEncoder(commandBuffer, target: working, clear: nil)
        encoder.setRenderPipelineState(transitionPipeline)
        var uniforms = TransitionUniforms(params: SIMD4(Float(Self.transitionIndex(transition.kind)),
                                                        Float(transition.progress), 0, 0))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TransitionUniforms>.stride, index: 0)
        encoder.setFragmentTexture(scratch[0], index: 0)
        encoder.setFragmentTexture(scratch[1], index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Draws a layer by itself into `target`, transparent where it doesn't cover (premultiplied).
    func drawAside(_ source: LayerSource, into target: MTLTexture, _ context: DrawContext,
                   keepAlive: inout [CVMetalTexture]) throws {
        let transparent = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let encoder = try layerEncoder(context.commandBuffer, target: target, clear: transparent)
        try draw(source, with: encoder, space: context.space, size: context.size, keepAlive: &keepAlive)
        encoder.endEncoding()
    }

    /// Runs blur, sharpen and shadow passes in order, ping-ponging through `temps`. Returns
    /// the texture holding the result (`input` itself when there's nothing to do).
    func runEffects(_ effects: [PixelEffect], on input: MTLTexture, temps: [MTLTexture],
                    commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        var current = input
        func free(_ busy: MTLTexture...) -> MTLTexture {
            temps.first { temp in !busy.contains { $0 === temp } } ?? temps[0]
        }
        for effect in effects {
            switch effect {
            case .blur(let radius):
                guard radius > 0.25 else { continue }
                let horizontal = free(current)
                try blur(current, into: horizontal, BlurPass(radius: radius, vertical: false), commandBuffer: commandBuffer)
                let vertical = free(current, horizontal)
                try blur(horizontal, into: vertical, BlurPass(radius: radius, vertical: true), commandBuffer: commandBuffer)
                current = vertical
            case .sharpen(let amount):
                let horizontal = free(current)
                try blur(current, into: horizontal, BlurPass(radius: 3, vertical: false), commandBuffer: commandBuffer)
                let blurred = free(current, horizontal)
                try blur(horizontal, into: blurred, BlurPass(radius: 3, vertical: true), commandBuffer: commandBuffer)
                let output = free(current, blurred)
                var uniforms = EffectUniforms(a: SIMD4(Float(amount), 0, 0, 0))
                try pass(sharpenPipeline, into: output, textures: [current, blurred], commandBuffer: commandBuffer,
                         bytes: &uniforms)
                current = output
            case .shadow(let opacity, let dx, let dy, let softness):
                let horizontal = free(current)
                let offset = SIMD2(Float(dx), Float(dy))
                try blur(current, into: horizontal, BlurPass(radius: softness, vertical: false, shadowOffset: offset),
                         commandBuffer: commandBuffer)
                let shadow = free(current, horizontal)
                try blur(horizontal, into: shadow, BlurPass(radius: softness, vertical: true), commandBuffer: commandBuffer)
                let output = free(current, shadow)
                var uniforms = EffectUniforms(a: SIMD4(0, 0, 0, Float(opacity)))
                try pass(shadowPipeline, into: output, textures: [current, shadow], commandBuffer: commandBuffer,
                         bytes: &uniforms)
                current = output
            }
        }
        return current
    }

    /// One direction of a separable Gaussian.
    struct BlurPass {
        var radius: Double
        var vertical: Bool
        /// Drop shadow: sample this far back (render pixels) and keep only the alpha.
        var shadowOffset: SIMD2<Float>?
    }

    /// Sigma is radius / 2, with at most 48 taps each side (wider blurs skip pixels).
    private func blur(_ source: MTLTexture, into target: MTLTexture, _ blurPass: BlurPass,
                      commandBuffer: MTLCommandBuffer) throws {
        let (radius, vertical) = (blurPass.radius, blurPass.vertical)
        let offset = blurPass.shadowOffset ?? .zero
        let alphaOnly = blurPass.shadowOffset != nil
        let sigma = max(radius / 2, 0.001)
        let reach = (3 * sigma).rounded(.up)
        let stride = max(1, (reach / 48).rounded(.up))
        let taps = radius > 0.25 ? Int((reach / stride).rounded(.up)) : 0
        let direction = vertical ? SIMD2<Float>(0, Float(stride)) : SIMD2<Float>(Float(stride), 0)
        var uniforms = EffectUniforms(a: SIMD4(direction.x, direction.y, Float(sigma / stride), Float(taps)),
                                      b: SIMD4(offset.x, offset.y, alphaOnly ? 1 : 0, 0))
        try pass(blurPipeline, into: target, textures: [source], commandBuffer: commandBuffer, bytes: &uniforms)
    }

    /// A full-screen pass of `pipeline` reading `textures`, writing every pixel of `target`.
    private func pass<Uniforms>(_ pipeline: MTLRenderPipelineState, into target: MTLTexture, textures: [MTLTexture],
                                commandBuffer: MTLCommandBuffer, bytes: inout Uniforms) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw RenderError.textureCreationFailed
        }
        encoder.setRenderPipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        encoder.setFragmentBytes(&bytes, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func copy(_ source: MTLTexture, to target: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw RenderError.textureCreationFailed }
        blit.copy(from: source, to: target)
        blit.endEncoding()
    }

    /// A premultiplied texture over what `encoder` is drawing into.
    func composite(_ texture: MTLTexture, opacity: Double, with encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(overPipeline)
        var uniforms = EffectUniforms(a: SIMD4(Float(min(max(opacity, 0), 1)), 0, 0, 0))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setRenderPipelineState(layerPipeline)
    }
}
