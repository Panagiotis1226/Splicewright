import Foundation

/// Final Cut Pro 7 XML (`xmeml`), the format Premiere Pro exports with File ▸ Export ▸ Final
/// Cut Pro XML and imports with File ▸ Import; DaVinci Resolve reads and writes it too.
public enum FCP7XML {
    // MARK: - Reading

    public static func read(_ data: Data) throws -> InterchangeTimeline {
        let root: XMLNode
        do { root = try XMLNode.parse(data) } catch { throw InterchangeFormat.ReadError.invalid("\(error)") }
        guard root.name == "xmeml" else { throw InterchangeFormat.ReadError.unknownFormat }
        let sequences = root.descendants("sequence").filter { $0.child("media") != nil }
        guard let sequence = sequences.first else { throw InterchangeFormat.ReadError.noTimeline }
        let rate = Self.rate(sequence.child("rate")) ?? .fps30
        let format = sequence["media", "video", "format", "samplecharacteristics"]
        var files: [String: InterchangeMedia] = [:]
        // Files are described in full once and referred to by ID after that.
        for file in root.descendants("file") where file.child("pathurl") != nil || file.child("name") != nil {
            guard let id = file.attributes["id"], files[id] == nil,
                  let path = file.value("pathurl").flatMap(InterchangeMedia.path(fromURL:)) else { continue }
            let fileRate = Self.rate(file.child("rate")) ?? rate
            let video = file["media", "video", "samplecharacteristics"]
            files[id] = InterchangeMedia(
                path: path, name: file.value("name"),
                duration: file.value("duration").flatMap(Int64.init).map { RationalTime(frames: $0, rate: fileRate) },
                hasVideo: file["media", "video"] != nil || file.child("media") == nil,
                hasAudio: file["media", "audio"] != nil || file.child("media") == nil,
                width: video?.value("width").flatMap(Int.init), height: video?.value("height").flatMap(Int.init))
        }
        var timeline = InterchangeTimeline(name: sequence.value("name") ?? "Imported Sequence",
                                           width: format?.value("width").flatMap(Int.init) ?? 0,
                                           height: format?.value("height").flatMap(Int.init) ?? 0, rate: rate)
        for (index, track) in (sequence["media", "video"]?.children("track") ?? []).enumerated() {
            let (clips, transitions) = readTrack(track, isAudio: false, index: index, rate: rate, files: files)
            timeline.videoTracks.append(clips)
            timeline.transitions += transitions
        }
        for (index, track) in (sequence["media", "audio"]?.children("track") ?? []).enumerated() {
            let (clips, transitions) = readTrack(track, isAudio: true, index: index, rate: rate, files: files)
            timeline.audioTracks.append(clips)
            timeline.transitions += transitions
        }
        mergeStereoPairs(&timeline)
        timeline.markers = sequence.children("marker").compactMap { marker(from: $0, rate: rate) }
        return timeline
    }

    /// `<rate><timebase>30</timebase><ntsc>TRUE</ntsc></rate>` → 29.97.
    static func rate(_ node: XMLNode?) -> FrameRate? {
        guard let node, let base = node.value("timebase").flatMap(Double.init), base > 0 else { return nil }
        let timebase = Int32(base.rounded())
        return node.value("ntsc")?.uppercased() == "TRUE" ? FrameRate(numerator: timebase * 1000, denominator: 1001)
                                                         : FrameRate(numerator: timebase)
    }

    private enum Item {
        case clip(XMLNode)
        case transition(start: Int64, end: Int64, cut: Int64, node: XMLNode)
    }

    private static func readTrack(_ track: XMLNode, isAudio: Bool, index: Int, rate: FrameRate,
                                  files: [String: InterchangeMedia]) -> ([InterchangeClip], [InterchangeTransition]) {
        let items: [Item] = track.children.compactMap { node in
            switch node.name {
            case "clipitem": return .clip(node)
            case "transitionitem":
                guard let start = node.value("start").flatMap(Int64.init), let end = node.value("end").flatMap(Int64.init)
                else { return nil }
                let alignment = node.value("alignment") ?? "center"
                let cut = alignment.hasPrefix("start") ? start : alignment.hasPrefix("end") ? end : (start + end) / 2
                return .transition(start: start, end: end, cut: cut, node: node)
            default: return nil
            }
        }
        var clips: [InterchangeClip] = []
        var transitions: [InterchangeTransition] = []
        for (position, item) in items.enumerated() {
            switch item {
            case .transition(let start, let end, let cut, let node):
                let name = node.value("effect", "name") ?? node.value("effect", "effectid") ?? ""
                transitions.append(InterchangeTransition(isAudio: isAudio, track: index, frame: cut, before: cut - start,
                                                         after: end - cut, kind: transitionKind(name, isAudio: isAudio)))
            case .clip(let node):
                // -1 means "at the neighbouring transition's cut".
                func cut(before: Bool) -> Int64? {
                    let neighbours = before ? Array(items[..<position].reversed()) : Array(items[(position + 1)...])
                    if case .transition(_, _, let cut, _)? = neighbours.first { return cut }
                    return nil
                }
                guard let clip = readClip(node, rate: rate, files: files, cut: cut) else { continue }
                clips.append(clip)
            }
        }
        return (clips.sorted { $0.start < $1.start }, transitions)
    }

    private static func readClip(_ node: XMLNode, rate: FrameRate, files: [String: InterchangeMedia],
                                 cut: (Bool) -> Int64?) -> InterchangeClip? {
        let clipRate = Self.rate(node.child("rate")) ?? rate
        let speedEffect = node.children("filter").compactMap { $0.child("effect") }
            .first { $0.value("effectid")?.lowercased() == "timeremap" }
        let speedValue = speedEffect.flatMap { parameter($0, "speed") }.flatMap(Double.init) ?? 100
        let reversed = speedEffect.flatMap { parameter($0, "reverse") }?.uppercased() == "TRUE"
        let inFrame = node.value("in").flatMap(Int64.init) ?? 0
        let outFrame = node.value("out").flatMap(Int64.init)
        var start = node.value("start").flatMap(Int64.init) ?? -1
        var end = node.value("end").flatMap(Int64.init) ?? -1
        if start < 0 { start = cut(true) ?? -1 }
        if end < 0 { end = cut(false) ?? -1 }
        let factor = max(abs(speedValue), 0.01) / 100
        let sourceFrames = outFrame.map { Double($0 - inFrame) } ?? 0
        let timelineFrames = Int64((sourceFrames * rate.framesPerSecond / clipRate.framesPerSecond / factor).rounded())
        if start < 0 && end >= 0 { start = end - timelineFrames }
        if end < 0 && start >= 0 { end = start + timelineFrames }
        guard start >= 0, end > start else { return nil }
        let media = node.child("file")?.attributes["id"].flatMap { files[$0] }
        let opacity = node.children("filter").compactMap { $0.child("effect") }
            .first { $0.value("effectid")?.lowercased() == "opacity" }
            .flatMap { parameter($0, "opacity") }.flatMap(Double.init).map { $0 / 100 } ?? 1
        let level = node.children("filter").compactMap { $0.child("effect") }
            .first { $0.value("effectid")?.lowercased() == "audiolevels" }
            .flatMap { parameter($0, "level") }.flatMap(Double.init)
        return InterchangeClip(name: node.value("name") ?? media?.name ?? "Clip", media: media, start: start,
                               duration: end - start, sourceStart: RationalTime(frames: inFrame, rate: clipRate),
                               speed: reversed ? -abs(speedValue) : speedValue,
                               isEnabled: node.value("enabled")?.uppercased() != "FALSE", opacity: opacity,
                               gainDB: level.map { $0 > 0 ? 20 * log10($0) : Mixer.silentDB } ?? 0)
    }

    private static func parameter(_ effect: XMLNode, _ id: String) -> String? {
        effect.children("parameter").first { $0.value("parameterid")?.lowercased() == id }?.value("value")
    }

    static func transitionKind(_ name: String, isAudio: Bool) -> TransitionKind {
        let lower = name.lowercased()
        if isAudio { return lower.contains("gain") || lower.contains("0db") ? .constantGain : .constantPower }
        if lower.contains("black") { return .dipToBlack }
        if lower.contains("white") { return .dipToWhite }
        if lower.contains("film") { return .filmDissolve }
        return .crossDissolve
    }

    private static func marker(from node: XMLNode, rate: FrameRate) -> Marker? {
        guard let frame = node.value("in").flatMap(Int64.init), frame >= 0 else { return nil }
        let out = node.value("out").flatMap(Int64.init) ?? -1
        return Marker(frame: frame, duration: out > frame ? out - frame : 0, name: node.value("name") ?? "",
                      comment: node.value("comment") ?? "")
    }

    /// Premiere writes a stereo file as one clip per channel on two tracks; keep one, so the
    /// sound isn't doubled (a clip here plays all of its file's channels).
    static func mergeStereoPairs(_ timeline: inout InterchangeTimeline) {
        var seen: Set<String> = []
        for track in timeline.audioTracks.indices {
            timeline.audioTracks[track].removeAll { clip in
                guard let path = clip.media?.path else { return false }
                return !seen.insert("\(path)|\(clip.start)|\(clip.duration)|\(clip.sourceStart.seconds)").inserted
            }
        }
        while let last = timeline.audioTracks.last, last.isEmpty, timeline.audioTracks.count > 1 {
            timeline.audioTracks.removeLast()
        }
    }

    // MARK: - Writing

    public static func write(_ timeline: InterchangeTimeline) -> String {
        let rate = timeline.rate
        let root = XMLNode("xmeml", ["version": "4"])
        let sequence = root.add(XMLNode("sequence", ["id": "sequence-1"]))
        sequence.add("name", timeline.name)
        sequence.add("duration", String(timeline.durationFrames))
        sequence.add(rateNode(rate))
        let media = sequence.add(XMLNode("media"))
        let video = media.add(XMLNode("video"))
        let format = video.add(XMLNode("format"))
        let characteristics = format.add(XMLNode("samplecharacteristics"))
        characteristics.add(rateNode(rate))
        characteristics.add("width", String(timeline.width))
        characteristics.add("height", String(timeline.height))
        characteristics.add("pixelaspectratio", "square")
        var writer = Writer(rate: rate)
        for (index, clips) in timeline.videoTracks.enumerated() {
            video.add(writer.track(clips, transitions: timeline.transitions.filter { !$0.isAudio && $0.track == index },
                                   isAudio: false))
        }
        let audio = media.add(XMLNode("audio"))
        for (index, clips) in timeline.audioTracks.enumerated() {
            let track = writer.track(clips, transitions: timeline.transitions.filter { $0.isAudio && $0.track == index },
                                     isAudio: true)
            // Premiere reads this as a stereo track, so one clip carries both channels.
            track.attributes["premiereTrackType"] = "Stereo"
            audio.add(track)
        }
        for marker in timeline.markers {
            let node = sequence.add(XMLNode("marker"))
            node.add("name", marker.name)
            node.add("comment", marker.comment)
            node.add("in", String(marker.frame))
            node.add("out", marker.duration > 0 ? String(marker.end) : "-1")
        }
        return root.document(doctype: "<!DOCTYPE xmeml>")
    }

    static func rateNode(_ rate: FrameRate) -> XMLNode {
        let node = XMLNode("rate")
        let ntsc = rate.denominator == 1001
        node.add("timebase", String(ntsc ? Int(rate.numerator / 1000) : Int((rate.framesPerSecond).rounded())))
        node.add("ntsc", ntsc ? "TRUE" : "FALSE")
        return node
    }

    private struct Writer {
        let rate: FrameRate
        var fileIDs: [String: String] = [:]
        var clipCount = 0

        init(rate: FrameRate) { self.rate = rate }

        mutating func track(_ clips: [InterchangeClip], transitions: [InterchangeTransition], isAudio: Bool) -> XMLNode {
            let track = XMLNode("track")
            // Clips meeting a transition at a cut (not a fade at a free edge) give -1.
            let cuts = Set(transitions.filter { $0.before > 0 && $0.after > 0 }.map(\.frame))
            var entries: [(Int64, XMLNode)] = []
            for clip in clips {
                entries.append((clip.start, clipItem(clip, isAudio: isAudio, startsAtTransition: cuts.contains(clip.start),
                                                     endsAtTransition: cuts.contains(clip.end))))
            }
            for transition in transitions {
                entries.append((transition.start, transitionItem(transition)))
            }
            for (_, node) in entries.sorted(by: { $0.0 < $1.0 }) { track.add(node) }
            track.add("enabled", "TRUE")
            return track
        }

        mutating func clipItem(_ clip: InterchangeClip, isAudio: Bool, startsAtTransition: Bool,
                               endsAtTransition: Bool) -> XMLNode {
            clipCount += 1
            let node = XMLNode("clipitem", ["id": "clipitem-\(clipCount)"])
            node.add("name", clip.name)
            node.add("enabled", clip.isEnabled ? "TRUE" : "FALSE")
            let factor = abs(clip.speed) / 100
            let sourceIn = clip.sourceStart.frameIndex(at: rate)
            let sourceOut = sourceIn + Int64((Double(clip.duration) * factor).rounded())
            let mediaFrames = clip.media?.duration.map { $0.frameIndex(at: rate) } ?? sourceOut
            node.add("duration", String(max(mediaFrames, sourceOut)))
            node.add(FCP7XML.rateNode(rate))
            // Clips meeting a transition give -1 and let the transition say where the cut is.
            node.add("start", startsAtTransition ? "-1" : String(clip.start))
            node.add("end", endsAtTransition ? "-1" : String(clip.end))
            node.add("in", String(sourceIn))
            node.add("out", String(sourceOut))
            if let media = clip.media { node.add(file(media, frames: max(mediaFrames, sourceOut))) }
            if isAudio {
                let source = node.add(XMLNode("sourcetrack"))
                source.add("mediatype", "audio")
                source.add("trackindex", "1")
            }
            if clip.speed != 100 {
                node.add(filter("Time Remap", id: "timeremap", category: "motion", type: "motion",
                                parameters: [("speed", String(abs(clip.speed))), ("reverse", clip.speed < 0 ? "TRUE" : "FALSE"),
                                             ("variablespeed", "0")]))
            }
            if !isAudio && clip.opacity < 1 {
                node.add(filter("Opacity", id: "opacity", category: "motion", type: "motion",
                                parameters: [("opacity", String(clip.opacity * 100))]))
            }
            if isAudio && clip.gainDB != 0 {
                let level = clip.gainDB <= Mixer.silentDB ? 0 : pow(10, clip.gainDB / 20)
                node.add(filter("Audio Levels", id: "audiolevels", category: "audiolevels", type: "audiofilter",
                                parameters: [("level", String(level))]))
            }
            return node
        }

        mutating func file(_ media: InterchangeMedia, frames: Int64) -> XMLNode {
            if let id = fileIDs[media.path] { return XMLNode("file", ["id": id]) }
            let id = "file-\(fileIDs.count + 1)"
            fileIDs[media.path] = id
            let node = XMLNode("file", ["id": id])
            node.add("name", media.name)
            node.add("pathurl", media.url)
            node.add(FCP7XML.rateNode(rate))
            node.add("duration", String(frames))
            let mediaNode = node.add(XMLNode("media"))
            if media.hasVideo {
                let characteristics = mediaNode.add(XMLNode("video")).add(XMLNode("samplecharacteristics"))
                if let width = media.width, let height = media.height {
                    characteristics.add("width", String(width))
                    characteristics.add("height", String(height))
                }
            }
            if media.hasAudio {
                let audio = mediaNode.add(XMLNode("audio"))
                audio.add("channelcount", "2")
            }
            return node
        }

        func transitionItem(_ transition: InterchangeTransition) -> XMLNode {
            let node = XMLNode("transitionitem")
            node.add("start", String(transition.start))
            node.add("end", String(transition.end))
            switch transition.alignment {
            case .center: node.add("alignment", "center")
            case .startAtCut: node.add("alignment", "start-black")
            case .endAtCut: node.add("alignment", "end-black")
            }
            node.add(FCP7XML.rateNode(rate))
            let effect = node.add(XMLNode("effect"))
            let (name, id) = transition.isAudio ? ("Cross Fade (+3dB)", "KGAudioTransCrossFade3dB")
                : transition.kind == .dipToBlack ? ("Dip to Black", "Dip to Black")
                : transition.kind == .dipToWhite ? ("Dip to White", "Dip to White") : ("Cross Dissolve", "Cross Dissolve")
            effect.add("name", name)
            effect.add("effectid", id)
            effect.add("effecttype", "transition")
            effect.add("mediatype", transition.isAudio ? "audio" : "video")
            return node
        }

        func filter(_ name: String, id: String, category: String, type: String, parameters: [(String, String)]) -> XMLNode {
            let filter = XMLNode("filter")
            let effect = filter.add(XMLNode("effect"))
            effect.add("name", name)
            effect.add("effectid", id)
            effect.add("effectcategory", category)
            effect.add("effecttype", type)
            for (key, value) in parameters {
                let parameter = effect.add(XMLNode("parameter"))
                parameter.add("parameterid", key)
                parameter.add("value", value)
            }
            return filter
        }
    }
}
