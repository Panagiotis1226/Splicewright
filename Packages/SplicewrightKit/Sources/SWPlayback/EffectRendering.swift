import Foundation
import SWCore

/// Turns resolved effect values (sequence pixels, percent, degrees) into what the renderer draws.
enum EffectRendering {
    /// Crop, Flip and Mirror become layer geometry; Blur, Sharpen and Drop Shadow become passes,
    /// in stack order. Sizes scale with the preview resolution (`pixelScale`).
    static func split(_ effects: [ResolvedEffect], pixelScale: Double) -> (LayerGeometry, [PixelEffect]) {
        var geometry = LayerGeometry.none
        var passes: [PixelEffect] = []
        for effect in effects {
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
                passes.append(.blur(radius: effect["blurriness"] * pixelScale))
            case .sharpen:
                passes.append(.sharpen(amount: effect["amount"] / 100))
            case .dropShadow:
                // Premiere's direction: 0° is straight up, clockwise (135° is down and to the right).
                let angle = effect["direction"] * .pi / 180
                let distance = effect["distance"] * pixelScale
                passes.append(.shadow(opacity: effect["opacity"] / 100, offsetX: sin(angle) * distance,
                                      offsetY: -cos(angle) * distance, softness: effect["softness"] * pixelScale))
            case .colorCorrection:
                let grade = ColorGrade(effect)
                if !grade.isNeutral { passes.append(.color(grade)) }
                if let curves = effect.curves, !curves.isIdentity { passes.append(.curves(curves)) }
            case .lut:
                if let path = effect.lutPath { passes.append(.lut(path: path, intensity: effect["intensity"] / 100)) }
            case .parametricEQ, .compressor, .hardLimiter:
                break
            }
        }
        return (geometry, passes)
    }
}
