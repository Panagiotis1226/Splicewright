import Foundation

/// A half-open range of sequence frames: `[start, end)`.
public struct FrameRange: Sendable, Hashable, Codable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    public init(start: Int64, length: Int64) {
        self.init(start: start, end: start + length)
    }

    public var length: Int64 { end - start }
    public var isEmpty: Bool { end <= start }

    public func contains(_ frame: Int64) -> Bool { frame >= start && frame < end }

    public func overlaps(_ other: FrameRange) -> Bool {
        start < other.end && other.start < end
    }
}

/// The working color space of a sequence. Media in other spaces is converted on render.
public enum SequenceColorSpace: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case rec709
    case rec2100HLG
    case rec2100PQ

    public var id: String { rawValue }

    public var color: ColorDescription {
        switch self {
        case .rec709: return .rec709
        case .rec2100HLG: return .rec2100HLG
        case .rec2100PQ: return .rec2100PQ
        }
    }

    public var displayName: String {
        switch self {
        case .rec709: return "Rec.709 (SDR)"
        case .rec2100HLG: return "Rec.2100 HLG (HDR)"
        case .rec2100PQ: return "Rec.2100 PQ (HDR)"
        }
    }

    public var isHDR: Bool { self != .rec709 }
}

public struct SequenceSettings: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var colorSpace: SequenceColorSpace
    public var audioSampleRate: Int

    public init(width: Int, height: Int, frameRate: FrameRate, colorSpace: SequenceColorSpace,
                audioSampleRate: Int = 48_000) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.colorSpace = colorSpace
        self.audioSampleRate = audioSampleRate
    }

    public static let uhd4K2997 = SequenceSettings(width: 3840, height: 2160, frameRate: .fps29_97, colorSpace: .rec709)

    public struct Resolution: Sendable, Hashable, Identifiable {
        public var name: String
        public var width: Int
        public var height: Int
        public var id: String { name }
    }

    public static let resolutions: [Resolution] = [
        Resolution(name: "UHD 4K (3840×2160)", width: 3840, height: 2160),
        Resolution(name: "DCI 4K (4096×2160)", width: 4096, height: 2160),
        Resolution(name: "1080p (1920×1080)", width: 1920, height: 1080),
        Resolution(name: "Vertical 4K (2160×3840)", width: 2160, height: 3840),
        Resolution(name: "Vertical 1080p (1080×1920)", width: 1080, height: 1920),
    ]

    /// Settings that match a clip, like Premiere's "New Sequence from Clip".
    public static func matching(_ info: MediaInfo) -> SequenceSettings {
        guard let video = info.video else { return .uhd4K2997 }
        let colorSpace: SequenceColorSpace
        switch video.dynamicRange {
        case .sdr: colorSpace = .rec709
        case .hlg: colorSpace = .rec2100HLG
        case .pq: colorSpace = .rec2100PQ
        }
        let rate = video.frameRate.flatMap { rate in FrameRate.standard.contains(rate) ? rate : nil }
            ?? FrameRate.nearestStandard(to: video.nominalFPS, tolerance: 0.05) ?? .fps29_97
        return SequenceSettings(width: max(2, video.width), height: max(2, video.height),
                                frameRate: rate, colorSpace: colorSpace)
    }

    public var summary: String {
        "\(width)×\(height) · \(frameRate.displayName) fps · \(colorSpace.displayName)"
    }
}

public enum TrackKind: String, Sendable, Hashable, Codable {
    case video, audio
}

/// A clip on a timeline track. Positions are in sequence frames; the source position is
/// media time, so media at any frame rate plays back in real time.
public struct Clip: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var mediaID: UUID
    public var name: String
    public var start: Int64
    public var duration: Int64
    /// Media time of the clip's first frame.
    public var sourceStart: RationalTime
    /// Clips sharing a link ID (a clip's video and audio) are selected and edited together.
    public var linkID: UUID?
    public var isEnabled: Bool
    /// Audio clip gain in dB (Premiere's Audio Gain, applied before Volume).
    public var gainDB: Double
    /// Set for a title (generated text) clip, whose `mediaID` is `Clip.generatedMediaID`.
    public var title: TitleSpec?
    /// Video: position, scale, rotation, anchor point and opacity, each keyframeable.
    public var motion: Motion
    /// Audio: level in dB, keyframeable (Premiere's Volume effect).
    public var volume: AnimatableProperty
    /// Playback speed in percent: constant (Speed/Duration) or keyframed (Time Remapping,
    /// timed from the clip's start). Schema 6.
    public var speed: AnimatableProperty
    /// Plays the source backwards (constant speed only).
    public var isReversed: Bool
    /// Keeps the pitch of sped-up or slowed-down audio.
    public var maintainsPitch: Bool
    /// Video effects, applied in order (schema 7).
    public var effects: [ClipEffect]
    /// An adjustment layer: no media; its effects apply to the tracks below (`mediaID` is
    /// `Clip.generatedMediaID`).
    public var isAdjustment: Bool
    /// Masks on Opacity: the clip shows only inside them (schema 10).
    public var opacityMasks: [Mask] = []

    public init(id: UUID = UUID(), mediaID: UUID, name: String, start: Int64, duration: Int64,
                sourceStart: RationalTime, linkID: UUID? = nil, isEnabled: Bool = true,
                opacity: Double = 1, gainDB: Double = 0, title: TitleSpec? = nil) {
        self.id = id
        self.mediaID = mediaID
        self.name = name
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
        self.linkID = linkID
        self.isEnabled = isEnabled
        self.gainDB = gainDB
        self.title = title
        motion = Motion()
        volume = AnimatableProperty([0])
        speed = AnimatableProperty([100])
        isReversed = false
        maintainsPitch = true
        effects = []
        isAdjustment = false
        self.opacity = opacity
    }

    /// Constant opacity, 0...1 (the value used when opacity isn't keyframed).
    public var opacity: Double {
        get { (motion.opacity.values.first ?? 100) / 100 }
        set { motion.opacity.values = [min(max(newValue, 0), 1) * 100] }
    }

    /// Whether the clip can be seen at all (keyframed opacity may rise above zero).
    public var isVisible: Bool { motion.opacity.isAnimated || opacity > 0 }

    public var end: Int64 { start + duration }
    public var range: FrameRange { FrameRange(start: start, end: end) }

    /// Source media time shown at sequence frame `frame`.
    public func sourceTime(atSequenceFrame frame: Int64, rate: FrameRate) -> RationalTime {
        guard isRetimed else { return sourceStart + RationalTime(frames: frame - start, rate: rate) }
        return sourceTime(atSequencePosition: Double(frame), rate: rate)
    }

    /// The sequence frame showing source time `time`.
    public func sequenceFrame(atSourceTime time: RationalTime, rate: FrameRate) -> Int64 {
        guard isRetimed else { return start + (time - sourceStart).frameIndex(at: rate) }
        let position = timing(rate: rate).clipFrame(atSourceOffset: (time - sourceStart).seconds)
        guard position.isFinite else { return position > 0 ? end : start }
        return start + Int64((position + 1e-6).rounded(.down))
    }

    private enum CodingKeys: String, CodingKey {
        case id, mediaID, name, start, duration, sourceStart, linkID, isEnabled, gainDB, title, motion, volume
        case speed, isReversed, maintainsPitch, effects, isAdjustment, opacityMasks
        /// Schema 3 and earlier stored a constant opacity (0...1).
        case opacity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mediaID = try container.decode(UUID.self, forKey: .mediaID)
        name = try container.decode(String.self, forKey: .name)
        start = try container.decode(Int64.self, forKey: .start)
        duration = try container.decode(Int64.self, forKey: .duration)
        sourceStart = try container.decode(RationalTime.self, forKey: .sourceStart)
        linkID = try container.decodeIfPresent(UUID.self, forKey: .linkID)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        gainDB = try container.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        title = try container.decodeIfPresent(TitleSpec.self, forKey: .title)
        motion = try container.decodeIfPresent(Motion.self, forKey: .motion) ?? Motion()
        volume = try container.decodeIfPresent(AnimatableProperty.self, forKey: .volume) ?? AnimatableProperty([0])
        speed = try container.decodeIfPresent(AnimatableProperty.self, forKey: .speed) ?? AnimatableProperty([100])
        isReversed = try container.decodeIfPresent(Bool.self, forKey: .isReversed) ?? false
        maintainsPitch = try container.decodeIfPresent(Bool.self, forKey: .maintainsPitch) ?? true
        effects = try container.decodeIfPresent([ClipEffect].self, forKey: .effects) ?? []
        isAdjustment = try container.decodeIfPresent(Bool.self, forKey: .isAdjustment) ?? false
        opacityMasks = try container.decodeIfPresent([Mask].self, forKey: .opacityMasks) ?? []
        if try container.decodeIfPresent(Motion.self, forKey: .motion) == nil,
           let legacy = try container.decodeIfPresent(Double.self, forKey: .opacity) {
            opacity = legacy
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mediaID, forKey: .mediaID)
        try container.encode(name, forKey: .name)
        try container.encode(start, forKey: .start)
        try container.encode(duration, forKey: .duration)
        try container.encode(sourceStart, forKey: .sourceStart)
        try container.encodeIfPresent(linkID, forKey: .linkID)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(gainDB, forKey: .gainDB)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(motion, forKey: .motion)
        try container.encode(volume, forKey: .volume)
        // 100% forwards is the default; leave it out so unchanged clips read as before.
        if speed != AnimatableProperty([100]) { try container.encode(speed, forKey: .speed) }
        if isReversed { try container.encode(isReversed, forKey: .isReversed) }
        if !maintainsPitch { try container.encode(maintainsPitch, forKey: .maintainsPitch) }
        if !effects.isEmpty { try container.encode(effects, forKey: .effects) }
        if isAdjustment { try container.encode(isAdjustment, forKey: .isAdjustment) }
        if !opacityMasks.isEmpty { try container.encode(opacityMasks, forKey: .opacityMasks) }
    }
}

public struct Track: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var kind: TrackKind
    /// Sorted by start; never overlapping.
    public var clips: [Clip]
    public var isLocked: Bool
    /// Sync-locked tracks follow ripple edits made on other tracks.
    public var isSyncLocked: Bool
    /// Eye (video) or the inverse of Mute (audio).
    public var isOutputEnabled: Bool
    public var isSolo: Bool
    /// Source patching: Insert/Overwrite from the Source monitor land on targeted tracks.
    public var isTargeted: Bool
    /// Transitions at this track's cuts and clip edges. See `resolvedTransitions`.
    public var transitions: [Transition]
    /// Audio Track Mixer fader, in dB (`Mixer.silentDB` or below is silent). Schema 8.
    public var volumeDB: Double = 0
    /// Audio Track Mixer pan, -100 (left) to 100 (right). Schema 8.
    public var pan: Double = 0

    public init(id: UUID = UUID(), kind: TrackKind, clips: [Clip] = [], isLocked: Bool = false,
                isSyncLocked: Bool = true, isOutputEnabled: Bool = true, isSolo: Bool = false,
                isTargeted: Bool = false, transitions: [Transition] = []) {
        self.id = id
        self.kind = kind
        self.clips = clips
        self.isLocked = isLocked
        self.isSyncLocked = isSyncLocked
        self.isOutputEnabled = isOutputEnabled
        self.isSolo = isSolo
        self.isTargeted = isTargeted
        self.transitions = transitions
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, clips, isLocked, isSyncLocked, isOutputEnabled, isSolo, isTargeted, transitions, volumeDB, pan
    }

    /// Schema 2 files have no transitions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(TrackKind.self, forKey: .kind)
        clips = try container.decode([Clip].self, forKey: .clips)
        isLocked = try container.decode(Bool.self, forKey: .isLocked)
        isSyncLocked = try container.decode(Bool.self, forKey: .isSyncLocked)
        isOutputEnabled = try container.decode(Bool.self, forKey: .isOutputEnabled)
        isSolo = try container.decode(Bool.self, forKey: .isSolo)
        isTargeted = try container.decode(Bool.self, forKey: .isTargeted)
        transitions = try container.decodeIfPresent([Transition].self, forKey: .transitions) ?? []
        volumeDB = try container.decodeIfPresent(Double.self, forKey: .volumeDB) ?? 0
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0
    }

    public var end: Int64 { clips.last?.end ?? 0 }

    public func clip(at frame: Int64) -> Clip? {
        clips.first { $0.range.contains(frame) }
    }

    public func isEmpty(in range: FrameRange) -> Bool {
        !clips.contains { $0.range.overlaps(range) }
    }
}

/// In and out points on a sequence, in frames. The out point is inclusive, as in Premiere.
public struct SequenceMarks: Sendable, Hashable, Codable {
    public var inFrame: Int64?
    public var outFrame: Int64?

    public init(inFrame: Int64? = nil, outFrame: Int64? = nil) {
        self.inFrame = inFrame
        self.outFrame = outFrame
    }

    /// The marked range, or nil unless both points are set.
    public var range: FrameRange? {
        guard let inFrame, let outFrame, outFrame >= inFrame else { return nil }
        return FrameRange(start: inFrame, end: outFrame + 1)
    }
}

/// A Premiere-style sequence: stacked video tracks (V1 at the bottom) over audio tracks.
public struct EditSequence: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var settings: SequenceSettings
    /// Index 0 is V1, the bottom layer.
    public var videoTracks: [Track]
    /// Index 0 is A1.
    public var audioTracks: [Track]
    public var marks: SequenceMarks
    /// Subtitle tracks, drawn above all video. Schema 5.
    public var captionTracks: [CaptionTrack]
    /// Sequence markers, sorted by frame. Schema 7.
    public var markers: [Marker]
    /// The Audio Track Mixer's Mix fader, in dB. Schema 8.
    public var mixVolumeDB: Double = 0

    public init(id: UUID = UUID(), name: String, settings: SequenceSettings,
                videoTrackCount: Int = 3, audioTrackCount: Int = 3) {
        self.id = id
        self.name = name
        self.settings = settings
        videoTracks = (0..<max(1, videoTrackCount)).map { Track(kind: .video, isTargeted: $0 == 0) }
        audioTracks = (0..<max(1, audioTrackCount)).map { Track(kind: .audio, isTargeted: $0 == 0) }
        marks = SequenceMarks()
        captionTracks = []
        markers = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, settings, videoTracks, audioTracks, marks, captionTracks, markers, mixVolumeDB
    }

    /// Sequences saved before schema 5 have no caption tracks.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        settings = try container.decode(SequenceSettings.self, forKey: .settings)
        videoTracks = try container.decode([Track].self, forKey: .videoTracks)
        audioTracks = try container.decode([Track].self, forKey: .audioTracks)
        marks = try container.decodeIfPresent(SequenceMarks.self, forKey: .marks) ?? SequenceMarks()
        captionTracks = try container.decodeIfPresent([CaptionTrack].self, forKey: .captionTracks) ?? []
        markers = try container.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        mixVolumeDB = try container.decodeIfPresent(Double.self, forKey: .mixVolumeDB) ?? 0
    }

    public var rate: FrameRate { settings.frameRate }

    public var allTracks: [Track] { videoTracks + audioTracks }

    /// Frame just after the last clip.
    public var durationFrames: Int64 { allTracks.map(\.end).max() ?? 0 }

    public func track(_ id: UUID) -> Track? {
        videoTracks.first { $0.id == id } ?? audioTracks.first { $0.id == id }
    }

    public func trackName(_ id: UUID) -> String {
        if let index = videoTracks.firstIndex(where: { $0.id == id }) { return "V\(index + 1)" }
        if let index = audioTracks.firstIndex(where: { $0.id == id }) { return "A\(index + 1)" }
        return "?"
    }

    public func clip(_ id: UUID) -> Clip? {
        for track in allTracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }

    public func trackID(containing clipID: UUID) -> UUID? {
        allTracks.first { track in track.clips.contains { $0.id == clipID } }?.id
    }

    /// `ids` plus every clip linked to them.
    public func expandingLinks(_ ids: Set<UUID>) -> Set<UUID> {
        let links = Set(ids.compactMap { clip($0)?.linkID })
        guard !links.isEmpty else { return ids }
        var result = ids
        for track in allTracks {
            for clip in track.clips where clip.linkID.map(links.contains) == true {
                result.insert(clip.id)
            }
        }
        return result
    }

    /// Sorted, unique clip boundaries across all tracks (for up/down arrow navigation).
    public var editPoints: [Int64] {
        var points = Set<Int64>([0])
        for track in allTracks {
            for clip in track.clips {
                points.insert(clip.start)
                points.insert(clip.end)
            }
        }
        return points.sorted()
    }

    public func nextEditPoint(after frame: Int64) -> Int64? {
        editPoints.first { $0 > frame }
    }

    public func previousEditPoint(before frame: Int64) -> Int64? {
        editPoints.last { $0 < frame }
    }

    // MARK: - Tracks

    /// Adds a track above the existing ones of that kind.
    public mutating func addTrack(_ kind: TrackKind) {
        switch kind {
        case .video: videoTracks.append(Track(kind: .video))
        case .audio: audioTracks.append(Track(kind: .audio))
        }
    }

    /// Removes an empty track. At least one track of each kind is kept.
    public mutating func removeTrack(_ id: UUID) {
        guard let track = track(id), track.clips.isEmpty else { return }
        if track.kind == .video, videoTracks.count > 1 { videoTracks.removeAll { $0.id == id } }
        if track.kind == .audio, audioTracks.count > 1 { audioTracks.removeAll { $0.id == id } }
    }

    /// Changes a track's lock/sync/output/solo/target flags (never its clips). Targeting is
    /// exclusive per kind: it says where Insert/Overwrite from the Source monitor land.
    public mutating func setTrackFlags(_ id: UUID, _ change: (inout Track) -> Void) {
        guard let kind = track(id)?.kind else { return }
        updateTrack(id) { track in
            let clips = track.clips
            change(&track)
            track.clips = clips
        }
        if track(id)?.isTargeted == true {
            updateAllTracks { track in
                if track.id != id, track.kind == kind { track.isTargeted = false }
            }
        }
    }

    /// Sets clip properties (enabled, opacity, gain) without moving anything.
    public mutating func updateClipProperties(_ ids: Set<UUID>, _ change: (inout Clip) -> Void) {
        updateAllTracks { track in
            for index in track.clips.indices where ids.contains(track.clips[index].id) {
                let (start, duration, source) = (track.clips[index].start, track.clips[index].duration,
                                                 track.clips[index].sourceStart)
                change(&track.clips[index])
                track.clips[index].start = start
                track.clips[index].duration = duration
                track.clips[index].sourceStart = source
            }
        }
    }

    /// Links clips together (or unlinks them when `linked` is false).
    public mutating func setLinked(_ ids: Set<UUID>, _ linked: Bool) {
        let link: UUID? = linked ? UUID() : nil
        updateAllTracks { track in
            for index in track.clips.indices where ids.contains(track.clips[index].id) {
                track.clips[index].linkID = link
            }
        }
    }

    // MARK: - Track mutation helpers

    mutating func updateTrack(_ id: UUID, _ change: (inout Track) -> Void) {
        if let index = videoTracks.firstIndex(where: { $0.id == id }) {
            change(&videoTracks[index])
        } else if let index = audioTracks.firstIndex(where: { $0.id == id }) {
            change(&audioTracks[index])
        }
    }

    mutating func updateAllTracks(_ change: (inout Track) -> Void) {
        for index in videoTracks.indices { change(&videoTracks[index]) }
        for index in audioTracks.indices { change(&audioTracks[index]) }
    }
}
