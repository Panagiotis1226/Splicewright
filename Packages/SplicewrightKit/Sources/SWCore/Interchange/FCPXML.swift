import Foundation

/// FCPXML (Final Cut Pro; DaVinci Resolve imports and exports it). Final Cut has a primary
/// storyline (the spine) with clips connected to it in lanes, rather than tracks: lane 0 is
/// the spine, positive lanes are above it and negative lanes below. Reading maps lanes to
/// tracks; writing puts V1 on the spine (with gaps) and connects everything else to it.
public enum FCPXML {
    /// "1001/30000s", "10s" or "0s" as seconds.
    static func seconds(_ text: String?) -> Double? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), text.hasSuffix("s") else { return nil }
        text.removeLast()
        let parts = text.split(separator: "/")
        guard let numerator = Double(parts.first ?? "") else { return nil }
        guard parts.count == 2 else { return numerator }
        guard let denominator = Double(parts[1]), denominator != 0 else { return nil }
        return numerator / denominator
    }

    /// Frames at `rate` as an exact FCPXML time.
    static func time(_ frames: Int64, rate: FrameRate) -> String {
        frames == 0 ? "0s" : "\(frames * Int64(rate.denominator))/\(rate.numerator)s"
    }

    // MARK: - Reading

    private struct Asset {
        var media: InterchangeMedia
        var start: Double
    }

    private struct Context {
        var rate: FrameRate
        var assets: [String: Asset]
        var video: [Int: [InterchangeClip]] = [:]
        /// Keys: video lanes' own audio at their lane number; lanes below the spine at 1000 + depth.
        var audio: [Int: [InterchangeClip]] = [:]
        var transitions: [InterchangeTransition] = []
        var markers: [Marker] = []

        func frames(_ seconds: Double) -> Int64 { Int64((seconds * rate.framesPerSecond).rounded()) }
    }

    public static func read(_ data: Data) throws -> InterchangeTimeline {
        let root: XMLNode
        do { root = try XMLNode.parse(data) } catch { throw InterchangeFormat.ReadError.invalid("\(error)") }
        guard root.name == "fcpxml" else { throw InterchangeFormat.ReadError.unknownFormat }
        guard let sequence = root.descendants("sequence").first, let spine = sequence.child("spine") else {
            throw InterchangeFormat.ReadError.noTimeline
        }
        let resources = root.child("resources")
        var formats: [String: XMLNode] = [:]
        for format in resources?.children("format") ?? [] { if let id = format.attributes["id"] { formats[id] = format } }
        let format = sequence.attributes["format"].flatMap { formats[$0] }
        let rate = format.flatMap { frameRate($0.attributes["frameDuration"]) } ?? .fps30
        var assets: [String: Asset] = [:]
        for asset in resources?.children("asset") ?? [] {
            guard let id = asset.attributes["id"],
                  let source = asset.child("media-rep")?.attributes["src"] ?? asset.attributes["src"],
                  let path = InterchangeMedia.path(fromURL: source) else { continue }
            let assetFormat = asset.attributes["format"].flatMap { formats[$0] }
            let media = InterchangeMedia(
                path: path, name: asset.attributes["name"],
                duration: seconds(asset.attributes["duration"]).map { RationalTime(seconds: $0, timescale: 600_000) },
                hasVideo: asset.attributes["hasVideo"] == "1", hasAudio: asset.attributes["hasAudio"] == "1",
                width: assetFormat?.attributes["width"].flatMap(Int.init),
                height: assetFormat?.attributes["height"].flatMap(Int.init))
            assets[id] = Asset(media: media, start: seconds(asset.attributes["start"]) ?? 0)
        }
        var context = Context(rate: rate, assets: assets)
        let origin = seconds(sequence.attributes["tcStart"]) ?? 0
        readStoryline(spine.children, lane: 0, parentPosition: -origin, parentStart: 0, context: &context)

        var timeline = InterchangeTimeline(
            name: sequence.parentProjectName(in: root) ?? "Imported Sequence",
            width: format?.attributes["width"].flatMap(Int.init) ?? 0,
            height: format?.attributes["height"].flatMap(Int.init) ?? 0, rate: rate)
        let videoLanes = context.video.keys.sorted()
        timeline.videoTracks = (0...(videoLanes.last ?? 0)).map { lane in
            (context.video[lane] ?? []).sorted { $0.start < $1.start }
        }
        timeline.audioTracks = context.audio.keys.sorted().map { key in
            (context.audio[key] ?? []).sorted { $0.start < $1.start }
        }
        timeline.transitions = context.transitions
        timeline.markers = context.markers.sorted { $0.frame < $1.frame }
        return timeline
    }

    static func frameRate(_ frameDuration: String?) -> FrameRate? {
        guard var text = frameDuration?.trimmingCharacters(in: .whitespaces), text.hasSuffix("s") else { return nil }
        text.removeLast()
        let parts = text.split(separator: "/").compactMap { Int32($0) }
        guard parts.count == 2, parts[0] > 0 else { return nil }
        return FrameRate(numerator: parts[1], denominator: parts[0])
    }

    private static let clipNames: Set<String> = ["asset-clip", "clip", "video", "audio", "ref-clip", "mc-clip", "sync-clip"]

    /// Elements in one storyline, each positioned by its offset in the parent's time.
    private static func readStoryline(_ elements: [XMLNode], lane: Int, parentPosition: Double, parentStart: Double,
                                      context: inout Context) {
        for element in elements {
            let offset = seconds(element.attributes["offset"]) ?? parentStart
            let position = parentPosition + (offset - parentStart)
            let elementLane = element.attributes["lane"].flatMap(Int.init) ?? lane
            switch element.name {
            case "transition":
                guard lane == 0, let duration = seconds(element.attributes["duration"]) else { continue }
                let before = context.frames(duration / 2)
                let total = context.frames(duration)
                context.transitions.append(InterchangeTransition(
                    isAudio: false, track: 0, frame: context.frames(position) + before, before: before,
                    after: total - before, kind: FCP7XML.transitionKind(element.attributes["name"] ?? "", isAudio: false)))
            case "spine":
                // A secondary storyline: its clips play one after another in the lane it's in.
                readStoryline(element.children, lane: elementLane, parentPosition: parentPosition, parentStart: parentStart,
                              context: &context)
            case "gap", "title":
                readAttached(element, position: position, context: &context)
            default:
                guard clipNames.contains(element.name) else { continue }
                readClip(element, lane: elementLane, position: position, context: &context)
                readAttached(element, position: position, context: &context)
            }
        }
    }

    /// Connected clips and markers inside a spine element.
    private static func readAttached(_ element: XMLNode, position: Double, context: inout Context) {
        let start = seconds(element.attributes["start"]) ?? 0
        let connected = element.children.filter { $0.attributes["lane"] != nil }
        readStoryline(connected, lane: 0, parentPosition: position, parentStart: start, context: &context)
        for marker in element.children where marker.name == "marker" || marker.name == "chapter-marker" {
            let at = position + ((seconds(marker.attributes["start"]) ?? start) - start)
            guard at >= 0 else { continue }
            context.markers.append(Marker(frame: context.frames(at), name: marker.attributes["value"] ?? "",
                                          comment: marker.attributes["note"] ?? "",
                                          isChapter: marker.name == "chapter-marker"))
        }
    }

    private static func readClip(_ element: XMLNode, lane: Int, position: Double, context: inout Context) {
        guard let duration = seconds(element.attributes["duration"]), duration > 0 else { return }
        // A `clip` wraps its media in a child element that names the asset.
        let refNode = element.attributes["ref"] != nil ? element
            : element.descendants("video").first { $0.attributes["ref"] != nil } ?? element.descendants("asset-clip").first
            ?? element.descendants("audio").first { $0.attributes["ref"] != nil }
        guard let ref = refNode?.attributes["ref"], let asset = context.assets[ref] else { return }
        let start = seconds(element.attributes["start"]) ?? seconds(refNode?.attributes["start"]) ?? asset.start
        var speed = 100.0
        if let points = element.child("timeMap")?.children("timept"), let last = points.last,
           let time = seconds(last.attributes["time"]), let value = seconds(last.attributes["value"]), time > 0 {
            let first = points.first.flatMap { seconds($0.attributes["value"]) } ?? 0
            speed = (value - first) / time * 100
        }
        let gain = element.child("adjust-volume")?.attributes["amount"]
            .map { $0.replacingOccurrences(of: "dB", with: "") }.flatMap(Double.init) ?? 0
        let clip = InterchangeClip(
            name: element.attributes["name"] ?? asset.media.name, media: asset.media, start: context.frames(position),
            duration: context.frames(duration),
            sourceStart: RationalTime(seconds: max(start - asset.start, 0), timescale: 600_000),
            speed: speed == 0 ? 100 : speed, isEnabled: element.attributes["enabled"] != "0",
            opacity: element.child("adjust-blend")?.attributes["amount"].flatMap(Double.init) ?? 1, gainDB: gain)
        let enabled = element.attributes["srcEnable"] ?? "all"
        let isAudioElement = element.name == "audio"
        if lane >= 0, asset.media.hasVideo, enabled != "audio", !isAudioElement {
            context.video[lane, default: []].append(clip)
        }
        if asset.media.hasAudio, enabled != "video", element.attributes["muted"] != "1" {
            context.audio[lane >= 0 ? lane : 1000 - lane, default: []].append(clip)
        }
    }

    // MARK: - Writing

    public static func write(_ timeline: InterchangeTimeline) -> String {
        let rate = timeline.rate
        let root = XMLNode("fcpxml", ["version": "1.10"])
        let resources = root.add(XMLNode("resources"))
        resources.add(XMLNode("format", ["id": "r1", "frameDuration": time(1, rate: rate),
                                         "width": String(timeline.width), "height": String(timeline.height)]))
        var assetIDs: [String: String] = [:]
        for media in timeline.mediaFiles {
            let id = "r\(assetIDs.count + 2)"
            assetIDs[media.path] = id
            var attributes = ["id": id, "name": media.name, "start": "0s",
                              "hasVideo": media.hasVideo ? "1" : "0", "hasAudio": media.hasAudio ? "1" : "0"]
            if let duration = media.duration { attributes["duration"] = time(duration.frameIndex(at: rate), rate: rate) }
            if media.hasVideo { attributes["format"] = "r1" }
            if media.hasAudio {
                attributes["audioSources"] = "1"
                attributes["audioChannels"] = "2"
                attributes["audioRate"] = "48000"
            }
            let asset = resources.add(XMLNode("asset", attributes))
            asset.add(XMLNode("media-rep", ["kind": "original-media", "src": media.url]))
        }
        let library = root.add(XMLNode("library"))
        let event = library.add(XMLNode("event", ["name": "Splicewright"]))
        let project = event.add(XMLNode("project", ["name": timeline.name]))
        let sequence = project.add(XMLNode("sequence", ["format": "r1", "duration": time(timeline.durationFrames, rate: rate),
                                                        "tcStart": "0s", "tcFormat": "NDF", "audioLayout": "stereo",
                                                        "audioRate": "48k"]))
        var writer = SpineWriter(timeline: timeline, assetIDs: assetIDs)
        sequence.add(writer.spine())
        return root.document(doctype: "<!DOCTYPE fcpxml>")
    }

    /// A spine element and where it sits, for attaching connected clips and markers.
    private struct Placed {
        var node: XMLNode
        var position: Int64
        var duration: Int64
        var start: Int64
    }

    private struct SpineWriter {
        let timeline: InterchangeTimeline
        let assetIDs: [String: String]
        var rate: FrameRate { timeline.rate }

        init(timeline: InterchangeTimeline, assetIDs: [String: String]) {
            self.timeline = timeline
            self.assetIDs = assetIDs
        }

        mutating func spine() -> XMLNode {
            let spine = XMLNode("spine")
            var placed: [Placed] = []
            var position: Int64 = 0
            var consumedAudio: Set<String> = []
            let firstAudio = timeline.audioTracks.first ?? []
            for clip in timeline.videoTracks.first ?? [] {
                if clip.start > position { placed.append(gap(at: position, frames: clip.start - position)) }
                // A V1 clip with its own audio on A1 is one Final Cut clip with both.
                let partner = firstAudio.first { $0.media?.path == clip.media?.path && $0.start == clip.start
                    && $0.duration == clip.duration && $0.sourceStart == clip.sourceStart }
                if let partner { consumedAudio.insert(key(partner, track: 0)) }
                placed.append(clipElement(clip, lane: nil, enable: partner == nil ? "video" : "all", position: clip.start,
                                          parentStart: nil))
                position = clip.end
            }
            if timeline.durationFrames > position {
                placed.append(gap(at: position, frames: timeline.durationFrames - position))
            }
            // Transitions on the spine sit between its elements.
            var children = placed.map { ($0.position, 1, $0.node) }
            for transition in timeline.transitions where !transition.isAudio && transition.track == 0
                && transition.before > 0 && transition.after > 0 {
                let node = XMLNode("transition", ["name": transition.kind == .dipToBlack ? "Fade To Color" : "Cross Dissolve",
                                                  "offset": time(transition.start, rate: rate),
                                                  "duration": time(transition.duration, rate: rate)])
                children.append((transition.start, 0, node))
            }
            for (_, _, node) in children.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) { spine.add(node) }
            connect(placed, consumedAudio: consumedAudio)
            return spine
        }

        func key(_ clip: InterchangeClip, track: Int) -> String { "\(track)|\(clip.start)|\(clip.media?.path ?? "")" }

        func gap(at position: Int64, frames: Int64) -> Placed {
            let node = XMLNode("gap", ["name": "Gap", "offset": time(position, rate: rate), "start": "0s",
                                       "duration": time(frames, rate: rate)])
            return Placed(node: node, position: position, duration: frames, start: 0)
        }

        func clipElement(_ clip: InterchangeClip, lane: Int?, enable: String, position: Int64, parentStart: Int64?) -> Placed {
            let start = clip.sourceStart.frameIndex(at: rate)
            var attributes = ["name": clip.name, "duration": time(clip.duration, rate: rate),
                              "start": time(start, rate: rate), "srcEnable": enable]
            attributes["offset"] = time(position, rate: rate)
            if let lane { attributes["lane"] = String(lane) }
            if let ref = clip.media.flatMap({ assetIDs[$0.path] }) { attributes["ref"] = ref }
            if !clip.isEnabled { attributes["enabled"] = "0" }
            let node = XMLNode("asset-clip", attributes)
            if clip.gainDB != 0 { node.add(XMLNode("adjust-volume", ["amount": "\(clip.gainDB)dB"])) }
            if clip.opacity < 1 { node.add(XMLNode("adjust-blend", ["amount": String(clip.opacity)])) }
            if clip.speed != 100 {
                let span = Int64((Double(clip.duration) * clip.speed / 100).rounded())
                let map = node.add(XMLNode("timeMap"))
                map.add(XMLNode("timept", ["time": "0s", "value": time(start, rate: rate), "interp": "linear"]))
                map.add(XMLNode("timept", ["time": time(clip.duration, rate: rate),
                                           "value": time(start + span, rate: rate), "interp": "linear"]))
            }
            return Placed(node: node, position: position, duration: clip.duration, start: start)
        }

        /// Everything not on the spine, connected to the spine element it starts over.
        func connect(_ spine: [Placed], consumedAudio: Set<String>) {
            func parent(for frame: Int64) -> Placed? {
                spine.first { frame >= $0.position && frame < $0.position + $0.duration } ?? spine.last
            }
            func attach(_ clip: InterchangeClip, lane: Int, enable: String) {
                guard let parent = parent(for: clip.start) else { return }
                let offset = parent.start + (clip.start - parent.position)
                parent.node.add(clipElement(clip, lane: lane, enable: enable, position: offset, parentStart: parent.start).node)
            }
            for (index, clips) in timeline.videoTracks.enumerated().dropFirst() {
                for clip in clips { attach(clip, lane: index, enable: "video") }
            }
            for (index, clips) in timeline.audioTracks.enumerated() {
                for clip in clips where !consumedAudio.contains(key(clip, track: index)) {
                    attach(clip, lane: -(index + 1), enable: "audio")
                }
            }
            for marker in timeline.markers {
                guard let parent = parent(for: marker.frame) else { continue }
                var attributes = ["start": time(parent.start + (marker.frame - parent.position), rate: rate),
                                  "duration": time(max(marker.duration, 1), rate: rate), "value": marker.title]
                if !marker.comment.isEmpty { attributes["note"] = marker.comment }
                if marker.isChapter { attributes["posterOffset"] = "0s" }
                parent.node.add(XMLNode(marker.isChapter ? "chapter-marker" : "marker", attributes))
            }
        }
    }
}

private extension XMLNode {
    /// The `project` that holds this sequence (FCPXML names projects, not sequences).
    func parentProjectName(in root: XMLNode) -> String? {
        root.descendants("project").first { $0.children.contains { $0 === self } }?.attributes["name"]
    }
}
