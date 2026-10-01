import Foundation
import SWCore

/// A mask placed in render pixels: points and handles (offsets) with y down.
struct RenderMask: Hashable {
    var vertices: [Mask.Vertex]
    var mode: Mask.Mode
    var isInverted: Bool
    /// Render pixels of soft edge.
    var feather: Double
    /// 0...1.
    var opacity: Double
    /// Render pixels the edge grows (negative shrinks).
    var expansion: Double

    /// Whether the path can enclose anything.
    var isDrawable: Bool { vertices.count >= 2 }
}

/// Where a layer's picture lands in the frame, to place its masks.
struct MaskSpace {
    /// The layer's own pixels → render pixels.
    var transform: Affine2D
    /// The layer's own size in pixels (masks are fractions of it).
    var width: Double
    var height: Double
    /// Sequence pixels → render pixels (feather and expansion are in sequence pixels).
    var pixelScale: Double

    func place(_ mask: ResolvedMask) -> RenderMask {
        let vertices = mask.vertices.map { vertex -> Mask.Vertex in
            let point = transform.apply(x: vertex.x * width, y: vertex.y * height)
            let incoming = transform.apply(x: (vertex.x + vertex.inX) * width, y: (vertex.y + vertex.inY) * height)
            let outgoing = transform.apply(x: (vertex.x + vertex.outX) * width, y: (vertex.y + vertex.outY) * height)
            return Mask.Vertex(x: point.x, y: point.y, inX: incoming.x - point.x, inY: incoming.y - point.y,
                               outX: outgoing.x - point.x, outY: outgoing.y - point.y)
        }
        return RenderMask(vertices: vertices, mode: mask.mode, isInverted: mask.isInverted,
                          feather: mask.feather * pixelScale, opacity: mask.opacity,
                          expansion: mask.expansion * pixelScale)
    }

    func place(_ masks: [ResolvedMask]) -> [RenderMask] {
        masks.map { place($0) }.filter(\.isDrawable)
    }
}

/// Turns resolved effect values (sequence pixels, percent, degrees) into what the renderer draws.
enum EffectRendering {
    /// Crop, Flip and Mirror become layer geometry; Blur, Sharpen and Drop Shadow become passes,
    /// in stack order. Sizes scale with the preview resolution (`pixelScale`). An effect with
    /// masks (and `maskSpace` to place them) applies only inside them.
    static func split(_ effects: [ResolvedEffect], pixelScale: Double,
                      maskSpace: MaskSpace? = nil) -> (LayerGeometry, [PixelEffect]) {
        var geometry = LayerGeometry.none
        var passes: [PixelEffect] = []
        for effect in effects {
            let own = self.passes(for: effect, pixelScale: pixelScale, geometry: &geometry)
            let masks = maskSpace?.place(effect.masks) ?? []
            if masks.isEmpty || own.isEmpty {
                passes += own
            } else {
                passes.append(.masked(own, masks))
            }
        }
        return (geometry, passes)
    }

    private static func passes(for effect: ResolvedEffect, pixelScale: Double,
                               geometry: inout LayerGeometry) -> [PixelEffect] {
        switch effect.kind {
        case .crop:
            // Stacked crops add up, as they would cutting the same picture twice.
            geometry.crop.left = min(1, geometry.crop.left + effect["left"] / 100)
            geometry.crop.top = min(1, geometry.crop.top + effect["top"] / 100)
            geometry.crop.right = min(1, geometry.crop.right + effect["right"] / 100)
            geometry.crop.bottom = min(1, geometry.crop.bottom + effect["bottom"] / 100)
            geometry.featherPixels = max(geometry.featherPixels, effect["feather"] * pixelScale)
        case .horizontalFlip:
            geometry.flipHorizontal.toggle()
        case .verticalFlip:
            geometry.flipVertical.toggle()
        case .mirror:
            geometry.mirror = (effect["center"] / 100, effect["angle"] * .pi / 180)
        case .gaussianBlur:
            return [.blur(radius: effect["blurriness"] * pixelScale)]
        case .sharpen:
            return [.sharpen(amount: effect["amount"] / 100)]
        case .dropShadow:
            // Premiere's direction: 0° is straight up, clockwise (135° is down and to the right).
            let angle = effect["direction"] * .pi / 180
            let distance = effect["distance"] * pixelScale
            return [.shadow(opacity: effect["opacity"] / 100, offsetX: sin(angle) * distance,
                            offsetY: -cos(angle) * distance, softness: effect["softness"] * pixelScale)]
        case .colorCorrection:
            let grade = ColorGrade(effect)
            var passes: [PixelEffect] = grade.isNeutral ? [] : [.color(grade)]
            if let curves = effect.curves, !curves.isIdentity { passes.append(.curves(curves)) }
            return passes
        case .lut:
            if let path = effect.lutPath { return [.lut(path: path, intensity: effect["intensity"] / 100)] }
        case .parametricEQ, .compressor, .hardLimiter:
            break
        }
        return []
    }
}
