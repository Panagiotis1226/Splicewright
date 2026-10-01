import Foundation

/// The animatable properties of a clip, as in Premiere's Effect Controls.
public enum ClipProperty: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case position
    case scale
    case scaleWidth
    case rotation
    case anchorPoint
    case opacity
    /// Audio clips: level in dB.
    case volume

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .position: return "Position"
        case .scale: return "Scale"
        case .scaleWidth: return "Scale Width"
        case .rotation: return "Rotation"
        case .anchorPoint: return "Anchor Point"
        case .opacity: return "Opacity"
        case .volume: return "Level"
        }
    }

    public static let video: [ClipProperty] = [.position, .scale, .scaleWidth, .rotation, .anchorPoint, .opacity]

    /// Component labels; one per value.
    public var components: [String] {
        switch self {
        case .position, .anchorPoint: return ["X", "Y"]
        default: return [""]
        }
    }

    public var unit: String {
        switch self {
        case .position, .anchorPoint: return "px"
        case .scale, .scaleWidth, .opacity: return "%"
        case .rotation: return "°"
        case .volume: return "dB"
        }
    }

    public var defaultValues: [Double] {
        switch self {
        case .position, .anchorPoint: return [0, 0]
        case .scale, .scaleWidth, .opacity: return [100]
        case .rotation, .volume: return [0]
        }
    }

    /// Allowed range for each component.
    public var range: ClosedRange<Double> {
        switch self {
        case .position, .anchorPoint: return -100_000...100_000
        case .scale, .scaleWidth: return 0...10_000
        case .rotation: return -36_000...36_000
        case .opacity: return 0...100
        case .volume: return -96...15
        }
    }

    /// Value change per point when dragging the number left and right.
    public var dragStep: Double {
        switch self {
        case .position, .anchorPoint: return 1
        case .scale, .scaleWidth, .rotation: return 0.5
        case .opacity: return 0.5
        case .volume: return 0.1
        }
    }
}

/// Position, scale, rotation, anchor point and opacity. Position and anchor point are
/// offsets in sequence pixels from the frame's centre (Effect Controls shows them as
/// absolute coordinates); scale and opacity are percentages.
public struct Motion: Sendable, Hashable, Codable {
    public var position = AnimatableProperty([0, 0])
    public var scale = AnimatableProperty([100])
    public var scaleWidth = AnimatableProperty([100])
    /// When on, Scale applies to both axes; when off, Scale is the height and Scale Width the width.
    public var uniformScale = true
    public var rotation = AnimatableProperty([0])
    public var anchorPoint = AnimatableProperty([0, 0])
    public var opacity = AnimatableProperty([100])

    public init() {}

    public static let identity = Motion()

    public var isIdentity: Bool { self == .identity }

    public var isAnimated: Bool {
        ClipProperty.video.contains { self[$0].isAnimated }
    }

    public subscript(property: ClipProperty) -> AnimatableProperty {
        get {
            switch property {
            case .position: return position
            case .scale: return scale
            case .scaleWidth: return scaleWidth
            case .rotation: return rotation
            case .anchorPoint: return anchorPoint
            case .opacity, .volume: return opacity
            }
        }
        set {
            switch property {
            case .position: position = newValue
            case .scale: scale = newValue
            case .scaleWidth: scaleWidth = newValue
            case .rotation: rotation = newValue
            case .anchorPoint: anchorPoint = newValue
            case .opacity, .volume: opacity = newValue
            }
        }
    }

    /// Opacity (0...1) at a source time.
    public func opacity(at time: RationalTime) -> Double {
        min(max((opacity.value(at: time).first ?? 100) / 100, 0), 1)
    }

    /// The transform that applies motion to a layer that already fills the frame (after
    /// fitting), in render pixels. `scale` maps sequence pixels to render pixels (preview
    /// resolution).
    public func transform(at time: RationalTime, renderWidth: Double, renderHeight: Double,
                          scale pixelScale: Double) -> Affine2D {
        let pos = position.value(at: time)
        let anchor = anchorPoint.value(at: time)
        let height = (scale.value(at: time).first ?? 100) / 100
        let width = uniformScale ? height : (scaleWidth.value(at: time).first ?? 100) / 100
        let radians = (rotation.value(at: time).first ?? 0) * .pi / 180
        let centerX = renderWidth / 2
        let centerY = renderHeight / 2
        let anchorX = centerX + (anchor.first ?? 0) * pixelScale
        let anchorY = centerY + (anchor.last ?? 0) * pixelScale
        let rotate = Affine2D(a: cos(radians), b: sin(radians), c: -sin(radians), d: cos(radians), tx: 0, ty: 0)
        return Affine2D.translation(-anchorX, -anchorY)
            .concatenating(.scale(width, height))
            .concatenating(rotate)
            // As in Premiere, Position is where the anchor point lands in the frame.
            .concatenating(.translation(centerX + (pos.first ?? 0) * pixelScale, centerY + (pos.last ?? 0) * pixelScale))
    }
}
