import Foundation

/// OpenTimelineIO (`.otio`, JSON), which DaVinci Resolve 18.5+ imports and exports. A track is
/// a list of items laid end to end (gaps for space); transitions overlap their neighbours
/// instead of taking time.
public enum OTIO {
    typealias Object = [String: Any]

    // MARK: - Reading

    public static func read(_ data: Data) throws -> InterchangeTimeline {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? Object else {
            throw InterchangeFormat.ReadError.invalid("not JSON")
        }
        let timelineObject: Object
        if schema(root) == "Timeline" {
            timelineObject = root
        } else if let first = (root["children"] as? [Object])?.first(where: { schema($0) == "Timeline" }) {
            timelineObject = first
        } else {
            throw InterchangeFormat.ReadError.noTimeline
        }
        guard let stack = timelineObject["tracks"] as? Object, let tracks = stack["children"] as? [Object] else {
            throw InterchangeFormat.ReadError.noTimeline
        }
        let rate = timelineRate(timelineObject, tracks: tracks)
        var timeline = InterchangeTimeline(name: timelineObject["name"] as? String ?? "Imported Timeline", width: 0, height: 0,
                                           rate: rate)
        for track in tracks where schema(track) == "Track" {
            let isAudio = (track["kind"] as? String) == "Audio"
            let index = isAudio ? timeline.audioTracks.count : timeline.videoTracks.count
            let (clips, transitions) = readTrack(track, isAudio: isAudio, index: index, rate: rate)
            if isAudio { timeline.audioTracks.append(clips) } else { timeline.videoTracks.append(clips) }
            timeline.transitions += transitions
            timeline.markers += markers(track["markers"], offset: 0, rate: rate)
        }
        timeline.markers = (markers(stack["markers"], offset: 0, rate: rate) + timeline.markers).sorted { $0.frame < $1.frame }
        if let metadata = timelineObject["metadata"] as? Object {
            // Resolve records the timeline's resolution in its own metadata.
            let resolve = metadata["Resolve_OTIO"] as? Object
            timeline.width = (resolve?["Resolution"] as? Object)?["width"] as? Int ?? 0
            timeline.height = (resolve?["Resolution"] as? Object)?["height"] as? Int ?? 0
        }
        return timeline
    }

    static func schema(_ object: Object) -> String? {
        (object["OTIO_SCHEMA"] as? String)?.split(separator: ".").first.map(String.init)
    }

    /// An OTIO rate (a float like 23.976 or 29.97) as the frame rate it stands for.
    static func frameRate(_ value: Double) -> FrameRate {
        let candidates = FrameRate.standard
        if let match = candidates.first(where: { abs($0.framesPerSecond - value) < 0.01 }) { return match }
        return FrameRate(numerator: Int32(value.rounded()))
    }

    private static func timelineRate(_ timeline: Object, tracks: [Object]) -> FrameRate {
        if let start = timeline["global_start_time"] as? Object, let rate = start["rate"] as? Double { return frameRate(rate) }
        for track in tracks {
            for item in track["children"] as? [Object] ?? [] {
                if let range = item["source_range"] as? Object, let duration = range["duration"] as? Object,
                   let rate = duration["rate"] as? Double {
                    return frameRate(rate)
                }
            }
        }
        return .fps24
    }

    /// A RationalTime object as seconds.
    static func seconds(_ value: Any?) -> Double? {
        guard let time = value as? Object, let frames = time["value"] as? Double, let rate = time["rate"] as? Double,
              rate > 0 else { return nil }
        return frames / rate
    }

    private static func readTrack(_ track: Object, isAudio: Bool, index: Int, rate: FrameRate)
        -> ([InterchangeClip], [InterchangeTransition]) {
        var clips: [InterchangeClip] = []
        var transitions: [InterchangeTransition] = []
        var position = 0.0
        func frames(_ seconds: Double) -> Int64 { Int64((seconds * rate.framesPerSecond).rounded()) }
        for item in track["children"] as? [Object] ?? [] {
            let range = item["source_range"] as? Object
            let duration = seconds(range?["duration"]) ?? 0
            switch schema(item) {
            case "Transition":
                let before = seconds(item["in_offset"]) ?? 0
                let after = seconds(item["out_offset"]) ?? 0
                let type = item["transition_type"] as? String ?? ""
                transitions.append(InterchangeTransition(isAudio: isAudio, track: index, frame: frames(position),
                                                         before: frames(before), after: frames(after),
                                                         kind: FCP7XML.transitionKind(type, isAudio: isAudio)))
            case "Clip":
                let media = mediaReference(item)
                let available = media?.availableStart ?? 0
                let start = seconds(range?["start_time"]) ?? available
                let warp = (item["effects"] as? [Object])?.first { schema($0) == "LinearTimeWarp" }
                let scalar = warp?["time_scalar"] as? Double ?? 1
                // OTIO has no volume or opacity; Splicewright keeps them in its own metadata.
                let ours = (item["metadata"] as? Object)?["Splicewright"] as? Object
                clips.append(InterchangeClip(
                    name: item["name"] as? String ?? media?.media.name ?? "Clip", media: media?.media,
                    start: frames(position), duration: frames(duration),
                    sourceStart: RationalTime(seconds: max(start - available, 0), timescale: 600_000),
                    speed: scalar == 0 ? 100 : scalar * 100, isEnabled: item["enabled"] as? Bool ?? true,
                    opacity: ours?["opacity"] as? Double ?? 1, gainDB: ours?["gainDB"] as? Double ?? 0))
                position += duration
            default:
                // Gaps, and anything else that takes time (nested stacks become space here).
                position += duration
            }
        }
        return (clips, transitions)
    }

    private struct Reference {
        var media: InterchangeMedia
        var availableStart: Double
    }

    private static func mediaReference(_ clip: Object) -> Reference? {
        var reference = clip["media_reference"] as? Object
        if let references = clip["media_references"] as? Object {
            let key = clip["active_media_reference_key"] as? String ?? "DEFAULT_MEDIA"
            reference = references[key] as? Object ?? references.values.first as? Object
        }
        guard let reference, schema(reference) == "ExternalReference",
              let url = reference["target_url"] as? String, let path = InterchangeMedia.path(fromURL: url) else { return nil }
        let available = reference["available_range"] as? Object
        let duration = seconds(available?["duration"]).map { RationalTime(seconds: $0, timescale: 600_000) }
        return Reference(media: InterchangeMedia(path: path, name: reference["name"] as? String, duration: duration),
                         availableStart: seconds(available?["start_time"]) ?? 0)
    }

    private static func markers(_ value: Any?, offset: Double, rate: FrameRate) -> [Marker] {
        (value as? [Object] ?? []).compactMap { marker in
            guard let range = marker["marked_range"] as? Object, let start = seconds(range["start_time"]) else { return nil }
            let frames = Int64(((start + offset) * rate.framesPerSecond).rounded())
            let length = Int64(((seconds(range["duration"]) ?? 0) * rate.framesPerSecond).rounded())
            let color = (marker["color"] as? String).flatMap { MarkerColor.otio[$0.uppercased()] } ?? .green
            return Marker(frame: frames, duration: length, name: marker["name"] as? String ?? "",
                          comment: marker["comment"] as? String ?? "", color: color)
        }
    }

    // MARK: - Writing

    public static func write(_ timeline: InterchangeTimeline) -> Data {
        let rate = timeline.rate
        func time(_ frames: Int64) -> Object {
            ["OTIO_SCHEMA": "RationalTime.1", "rate": rate.framesPerSecond, "value": Double(frames)]
        }
        func range(_ start: Int64, _ duration: Int64) -> Object {
            ["OTIO_SCHEMA": "TimeRange.1", "start_time": time(start), "duration": time(duration)]
        }
        func track(_ clips: [InterchangeClip], kind: String, name: String, transitions: [InterchangeTransition]) -> Object {
            var children: [Object] = []
            var position: Int64 = 0
            for clip in clips {
                if clip.start > position {
                    children.append(["OTIO_SCHEMA": "Gap.1", "name": "", "source_range": range(0, clip.start - position)])
                }
                for transition in transitions where transition.frame == clip.start && transition.duration > 0 {
                    children.append(["OTIO_SCHEMA": "Transition.1", "name": "", "transition_type": "SMPTE_Dissolve",
                                     "in_offset": time(transition.before), "out_offset": time(transition.after)])
                }
                var object: Object = ["OTIO_SCHEMA": "Clip.2", "name": clip.name, "enabled": clip.isEnabled,
                                      "source_range": range(clip.sourceStart.frameIndex(at: rate), clip.duration),
                                      "active_media_reference_key": "DEFAULT_MEDIA", "markers": [Object](), "effects": [Object]()]
                if let media = clip.media {
                    var reference: Object = ["OTIO_SCHEMA": "ExternalReference.1", "name": media.name,
                                             "target_url": media.url]
                    if let duration = media.duration { reference["available_range"] = range(0, duration.frameIndex(at: rate)) }
                    object["media_references"] = ["DEFAULT_MEDIA": reference]
                }
                if clip.opacity < 1 || clip.gainDB != 0 {
                    object["metadata"] = ["Splicewright": ["opacity": clip.opacity, "gainDB": clip.gainDB]]
                }
                if clip.speed != 100 {
                    object["effects"] = [["OTIO_SCHEMA": "LinearTimeWarp.1", "name": "", "effect_name": "LinearTimeWarp",
                                          "time_scalar": clip.speed / 100]]
                }
                children.append(object)
                position = clip.end
            }
            return ["OTIO_SCHEMA": "Track.1", "name": name, "kind": kind, "children": children, "markers": [Object]()]
        }
        let video = timeline.videoTracks.enumerated().map { index, clips in
            track(clips, kind: "Video", name: "V\(index + 1)",
                  transitions: timeline.transitions.filter { !$0.isAudio && $0.track == index })
        }
        let audio = timeline.audioTracks.enumerated().map { index, clips in
            track(clips, kind: "Audio", name: "A\(index + 1)",
                  transitions: timeline.transitions.filter { $0.isAudio && $0.track == index })
        }
        let markers: [Object] = timeline.markers.map { marker in
            ["OTIO_SCHEMA": "Marker.2", "name": marker.name, "comment": marker.comment,
             "color": MarkerColor.otio.first { $0.value == marker.color }?.key ?? "GREEN",
             "marked_range": range(marker.frame, marker.duration)]
        }
        let object: Object = [
            "OTIO_SCHEMA": "Timeline.1", "name": timeline.name,
            "global_start_time": time(0),
            "metadata": ["Resolve_OTIO": ["Resolution": ["width": timeline.width, "height": timeline.height]]],
            "tracks": ["OTIO_SCHEMA": "Stack.1", "name": "tracks", "children": video + audio, "markers": markers],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}

extension MarkerColor {
    /// OTIO's marker colour names.
    static let otio: [String: MarkerColor] = [
        "GREEN": .green, "RED": .red, "PURPLE": .purple, "ORANGE": .orange, "YELLOW": .yellow,
        "WHITE": .white, "BLUE": .blue, "CYAN": .cyan,
    ]
}
