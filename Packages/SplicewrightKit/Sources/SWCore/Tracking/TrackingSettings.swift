import Foundation

/// How a mask tracker follows its object, chosen per mask in Effect Controls.
public struct TrackingSettings: Sendable, Hashable, Codable {
    /// What the tracker looks at.
    public enum Method: String, Sendable, Hashable, Codable, CaseIterable {
        /// Distinct corners inside the mask, each followed on its own; robust to parts being hidden.
        case points
        /// Every pixel of the mask's area matched at once; for soft detail with few corners.
        case texture
        /// The mask's colors against the background; survives turning and changing shape.
        case color

        public var displayName: String {
            switch self {
            case .points: return "Points"
            case .texture: return "Texture"
            case .color: return "Color"
            }
        }

        public var help: String {
            switch self {
            case .points: return "Follows distinct corners and details inside the mask. Best for most objects."
            case .texture: return "Matches the whole area at once. Best for faces, skin and fabric with few sharp details."
            case .color: return "Follows the mask's colors. Best for objects that turn or change shape but stand out in color."
            }
        }
    }

    /// How the mask may change from frame to frame.
    public enum Motion: String, Sendable, Hashable, Codable, CaseIterable {
        case position
        case positionScale
        case positionScaleRotation
        case affine
        case perspective

        public var displayName: String {
            switch self {
            case .position: return "Position"
            case .positionScale: return "Position & Scale"
            case .positionScaleRotation: return "Position, Scale & Rotation"
            case .affine: return "Skew (Affine)"
            case .perspective: return "Perspective"
            }
        }

        /// Numbers the motion has (its degrees of freedom).
        var parameterCount: Int {
            switch self {
            case .position: return 2
            case .positionScale: return 3
            case .positionScaleRotation: return 4
            case .affine: return 6
            case .perspective: return 8
            }
        }

        /// Point pairs needed to fix the motion.
        var minimumPoints: Int {
            switch self {
            case .position: return 1
            case .positionScale, .positionScaleRotation: return 2
            case .affine: return 3
            case .perspective: return 4
            }
        }
    }

    /// How far the object may move between frames.
    public enum SearchRange: String, Sendable, Hashable, Codable, CaseIterable {
        case small, normal, large

        public var displayName: String { rawValue.capitalized }

        /// Pyramid levels: each halves the picture, doubling how far a match can be found.
        public var pyramidLevels: Int {
            switch self {
            case .small: return 2
            case .normal: return 3
            case .large: return 5
            }
        }
    }

    /// The size frames are analysed at (the longer side), trading speed for precision.
    public enum Quality: String, Sendable, Hashable, Codable, CaseIterable {
        case faster, normal, precise

        public var displayName: String { rawValue.capitalized }

        public var analysisSize: Int {
            switch self {
            case .faster: return 480
            case .normal: return 960
            case .precise: return 1920
            }
        }
    }

    /// What each frame is compared with.
    public enum Reference: String, Sendable, Hashable, Codable, CaseIterable {
        /// The frame before: adapts as the object changes, but small errors can add up.
        case previousFrame
        /// The frame tracking started on: doesn't drift, but loses objects that change look.
        case firstFrame

        public var displayName: String { self == .previousFrame ? "Adapt Each Frame" : "Hold the First Frame" }
    }

    public var method: Method = .points
    public var motion: Motion = .positionScaleRotation
    public var searchRange: SearchRange = .normal
    public var quality: Quality = .normal
    public var reference: Reference = .previousFrame
    /// Stop (rather than keep guessing) where the object is lost: hidden, blurred or out of frame.
    public var stopsWhenLost = true

    public init() {}

    /// The motion the method can actually measure (Color follows a blob: no skew or perspective).
    public var effectiveMotion: Motion {
        method == .color && (motion == .affine || motion == .perspective) ? .positionScaleRotation : motion
    }
}
