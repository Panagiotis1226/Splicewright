import CoreGraphics
import CoreText
import Foundation
import Metal
import SWCore

/// Draws a title with Core Text into a frame-sized RGBA texture (premultiplied sRGB).
/// Textures are cached by title and size, so playback only rasterizes a title once.
final class TitleRasterizer {
    private struct Key: Hashable {
        var spec: TitleSpec
        var textOpacity: [TitleTextOpacity]
        var width: Int
        var height: Int
    }

    private let device: MTLDevice
    private var cache: [Key: MTLTexture] = [:]
    private var order: [Key] = []
    private let capacity = 32

    init(device: MTLDevice) {
        self.device = device
    }

    func texture(for spec: TitleSpec, textOpacity: [TitleTextOpacity] = [], width: Int, height: Int) -> MTLTexture? {
        var drawn = spec
        drawn.animation = nil
        let key = Key(spec: drawn, textOpacity: textOpacity, width: width, height: height)
        if let cached = cache[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return cached
        }
        guard let texture = makeTexture(drawn, textOpacity: textOpacity, width: width, height: height) else { return nil }
        cache[key] = texture
        order.append(key)
        if order.count > capacity { cache[order.removeFirst()] = nil }
        return texture
    }

    private func makeTexture(_ spec: TitleSpec, textOpacity: [TitleTextOpacity], width: Int,
                             height: Int) -> MTLTexture? {
        guard width > 0, height > 0,
              let pixels = Self.rasterize(spec, textOpacity: textOpacity, width: width, height: height) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    /// RGBA8 premultiplied sRGB pixels, top row first.
    static func rasterize(_ spec: TitleSpec, textOpacity: [TitleTextOpacity] = [], width: Int,
                          height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            draw(spec, textOpacity: textOpacity, in: context, size: CGSize(width: width, height: height), space: space)
            return true
        }
        return drawn ? pixels : nil
    }

    private static func draw(_ spec: TitleSpec, textOpacity: [TitleTextOpacity], in context: CGContext, size: CGSize,
                             space: CGColorSpace) {
        let (width, height) = (size.width, size.height)
        let fontSize = max(1, CGFloat(spec.size) * height)
        let font = Self.font(spec, size: fontSize)
        func color(_ value: TitleColor) -> CGColor {
            CGColor(colorSpace: space, components: [value.red, value.green, value.blue, value.alpha].map { CGFloat($0) })
                ?? CGColor(gray: 1, alpha: 1)
        }
        var alignment: CTTextAlignment
        switch spec.alignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        let paragraph = withUnsafeBytes(of: &alignment) { raw -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: raw.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        func attributed(_ extra: [CFString: Any], colors: [CFString: CGColor]) -> CFAttributedString {
            var attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTParagraphStyleAttributeName: paragraph]
            attributes.merge(extra) { $1 }
            attributes.merge(colors) { $1 }
            let string = CFAttributedStringCreate(nil, spec.text as CFString, attributes as CFDictionary)
                ?? CFAttributedStringCreate(nil, "" as CFString, nil)!
            return fading(string, textOpacity, colors: colors)
        }
        let fill = attributed([:], colors: [kCTForegroundColorAttributeName: color(spec.color)])

        // Lay the text out in a box at most 90% of the frame wide, centred on the title's position.
        let maxWidth = width * 0.9
        let framesetter = CTFramesetterCreateWithAttributedString(fill)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                  CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                                                  nil)
        let box = CGSize(width: min(maxWidth, ceil(fitted.width) + 2), height: ceil(fitted.height) + 2)
        // Core Graphics' origin is bottom left; positions are measured from the top.
        let center = CGPoint(x: CGFloat(spec.positionX) * width, y: (1 - CGFloat(spec.positionY)) * height)
        let rect = CGRect(x: center.x - box.width / 2, y: center.y - box.height / 2, width: box.width, height: box.height)

        if let backdrop = spec.backdrop {
            context.setFillColor(color(backdrop))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let background = spec.background {
            let padding = fontSize * 0.3
            context.setFillColor(color(background))
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: -padding, dy: -padding * 0.6),
                                   cornerWidth: padding * 0.5, cornerHeight: padding * 0.5, transform: nil))
            context.fillPath()
        }

        func drawText(_ string: CFAttributedString) {
            let setter = CTFramesetterCreateWithAttributedString(string)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil),
                                                 nil)
            CTFrameDraw(frame, context)
        }
        context.saveGState()
        if let shadow = spec.shadow {
            let offset = CGFloat(shadow.offset) * fontSize
            context.setShadow(offset: CGSize(width: offset, height: -offset), blur: CGFloat(shadow.blur) * fontSize,
                              color: color(shadow.color))
        }
        if let stroke = spec.stroke, stroke.width > 0 {
            // Core Text strokes are centred on the outline; draw the stroke under the fill so
            // only its outer half shows.
            let percent = CGFloat(stroke.width) * 200
            drawText(attributed([kCTStrokeWidthAttributeName: percent],
                                colors: [kCTStrokeColorAttributeName: color(stroke.color)]))
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        drawText(fill)
        context.restoreGState()
    }

    /// The text with parts hidden or faded: their fill and stroke colors at that opacity, so
    /// the layout (and so where every letter sits) doesn't change as they come in.
    private static func fading(_ string: CFAttributedString, _ parts: [TitleTextOpacity],
                               colors: [CFString: CGColor]) -> CFAttributedString {
        guard !parts.isEmpty, let mutable = CFAttributedStringCreateMutableCopy(nil, 0, string) else { return string }
        let length = CFAttributedStringGetLength(string)
        for part in parts {
            let location = min(max(part.location, 0), length)
            let range = CFRange(location: location, length: min(max(part.length, 0), length - location))
            guard range.length > 0 else { continue }
            for (name, color) in colors {
                let faded = color.copy(alpha: color.alpha * CGFloat(part.opacity)) ?? color
                CFAttributedStringSetAttribute(mutable, range, name, faded)
            }
        }
        return mutable
    }

    private static func font(_ spec: TitleSpec, size: CGFloat) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if spec.isBold { traits.insert(.traitBold) }
        if spec.isItalic { traits.insert(.traitItalic) }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: spec.fontFamily,
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: traits.rawValue],
        ] as CFDictionary)
        let base = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }
}
