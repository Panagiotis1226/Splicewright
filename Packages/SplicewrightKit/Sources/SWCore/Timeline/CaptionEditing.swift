import Foundation

/// Caption track edits. Captions on a track never overlap: moves and trims stop at the
/// neighbouring captions, as in Resolve's subtitle track.
public extension EditSequence {
    func captionTrack(_ id: UUID) -> CaptionTrack? {
        captionTracks.first { $0.id == id }
    }

    /// The track holding a caption, and the caption.
    func caption(_ id: UUID) -> (trackID: UUID, caption: Caption)? {
        for track in captionTracks {
            if let caption = track.captions.first(where: { $0.id == id }) { return (track.id, caption) }
        }
        return nil
    }

    @discardableResult
    mutating func addCaptionTrack(name: String, language: String, style: CaptionStyle = .standard,
                                  captions: [Caption] = []) -> UUID {
        var track = CaptionTrack(name: name, language: language, style: style, captions: captions)
        track.normalize()
        captionTracks.append(track)
        return track.id
    }

    mutating func removeCaptionTrack(_ id: UUID) {
        captionTracks.removeAll { $0.id == id }
    }

    /// Changes a track's name, language, style or flags. Locked tracks' captions can't change
    /// here; use the caption edits below.
    mutating func updateCaptionTrack(_ id: UUID, _ change: (inout CaptionTrack) -> Void) {
        guard let index = captionTracks.firstIndex(where: { $0.id == id }) else { return }
        let captions = captionTracks[index].captions
        change(&captionTracks[index])
        if captionTracks[index].isLocked { captionTracks[index].captions = captions }
        captionTracks[index].normalize()
    }

    /// Replaces a track's captions (after transcribing, importing or re-splitting).
    mutating func setCaptions(_ captions: [Caption], on trackID: UUID) {
        editCaptions(on: trackID) { $0 = captions }
    }

    mutating func setCaptionText(_ id: UUID, _ text: String) {
        editCaption(id) { $0.text = text }
    }

    /// Moves a caption to start at `frame`, stopping at its neighbours.
    mutating func moveCaption(_ id: UUID, to frame: Int64) {
        guard let found = caption(id), let track = captionTrack(found.trackID) else { return }
        let caption = found.caption
        let index = track.captions.firstIndex { $0.id == id } ?? 0
        let lower = index > 0 ? track.captions[index - 1].end : 0
        let upper = index + 1 < track.captions.count ? track.captions[index + 1].start : Int64.max
        let start = min(max(frame, lower), max(lower, upper - caption.duration))
        let delta = start - caption.start
        editCaption(id) { caption in
            caption.start = start
            for word in caption.words.indices { caption.words[word].start += delta }
        }
    }

    /// Moves one edge of a caption to `frame`, stopping at its neighbours and keeping at least a frame.
    mutating func trimCaption(_ id: UUID, edge: TrimEdge, to frame: Int64) {
        guard let found = caption(id), let track = captionTrack(found.trackID) else { return }
        let caption = found.caption
        let index = track.captions.firstIndex { $0.id == id } ?? 0
        switch edge {
        case .start:
            let lower = index > 0 ? track.captions[index - 1].end : 0
            let start = min(max(frame, lower), caption.end - 1)
            editCaption(id) { $0.duration = $0.end - start; $0.start = start }
        case .end:
            let upper = index + 1 < track.captions.count ? track.captions[index + 1].start : Int64.max
            let end = max(min(frame, upper), caption.start + 1)
            editCaption(id) { $0.duration = end - $0.start }
        }
    }

    /// Splits a caption at `frame`: at a word boundary when it has word timings, else by
    /// characters in proportion to time. Returns the new (right-hand) caption's ID.
    @discardableResult
    mutating func splitCaption(_ id: UUID, at frame: Int64) -> UUID? {
        guard let found = caption(id), frame > found.caption.start, frame < found.caption.end else { return nil }
        let (trackID, caption) = (found.trackID, found.caption)
        let halves = Self.splitText(of: caption, at: frame)
        var left = caption
        left.duration = frame - caption.start
        left.text = halves.left.text
        left.words = halves.left.words
        let right = Caption(start: frame, duration: caption.end - frame, text: halves.right.text, words: halves.right.words)
        editCaptions(on: trackID) { captions in
            guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
            captions.replaceSubrange(index...index, with: [left, right])
        }
        return right.id
    }

    /// Joins a caption with the one after it.
    mutating func mergeCaptionWithNext(_ id: UUID) {
        guard let trackID = caption(id)?.trackID else { return }
        editCaptions(on: trackID) { captions in
            guard let index = captions.firstIndex(where: { $0.id == id }), index + 1 < captions.count else { return }
            let next = captions.remove(at: index + 1)
            captions[index].duration = next.end - captions[index].start
            let joined = captions[index].text.replacingOccurrences(of: "\n", with: " ")
                + " " + next.text.replacingOccurrences(of: "\n", with: " ")
            captions[index].text = joined.trimmingCharacters(in: .whitespaces)
            captions[index].words += next.words
        }
    }

    mutating func deleteCaptions(_ ids: Set<UUID>) {
        for index in captionTracks.indices where !captionTracks[index].isLocked {
            captionTracks[index].captions.removeAll { ids.contains($0.id) }
        }
    }

    /// Adds an empty caption at `frame` (or after the caption there), returning its ID.
    @discardableResult
    mutating func addCaption(on trackID: UUID, at frame: Int64, duration: Int64, text: String = "") -> UUID? {
        guard let track = captionTrack(trackID), !track.isLocked else { return nil }
        let start = track.caption(at: frame)?.end ?? max(0, frame)
        let next = track.captions.first { $0.start >= start }?.start ?? Int64.max
        guard next > start else { return nil }
        let caption = Caption(start: start, duration: min(duration, next - start), text: text)
        editCaptions(on: trackID) { $0.append(caption) }
        return caption.id
    }

    /// Replaces text in every caption of a track (case-insensitive). Returns how many changed.
    @discardableResult
    mutating func replaceInCaptions(on trackID: UUID, _ find: String, with replacement: String) -> Int {
        guard !find.isEmpty else { return 0 }
        var count = 0
        editCaptions(on: trackID) { captions in
            for index in captions.indices {
                let replaced = captions[index].text.replacingOccurrences(of: find, with: replacement,
                                                                         options: .caseInsensitive)
                if replaced != captions[index].text {
                    captions[index].text = replaced
                    count += 1
                }
            }
        }
        return count
    }

    /// Moves every caption on a track by `delta` frames (none before frame 0).
    mutating func shiftCaptions(on trackID: UUID, by delta: Int64) {
        editCaptions(on: trackID) { captions in
            let shift = max(delta, -(captions.first?.start ?? 0))
            for index in captions.indices {
                captions[index].start += shift
                for word in captions[index].words.indices { captions[index].words[word].start += shift }
            }
        }
    }

    // MARK: - Helpers

    private mutating func editCaptions(on trackID: UUID, _ change: (inout [Caption]) -> Void) {
        guard let index = captionTracks.firstIndex(where: { $0.id == trackID }),
              !captionTracks[index].isLocked else { return }
        change(&captionTracks[index].captions)
        captionTracks[index].normalize()
    }

    private mutating func editCaption(_ id: UUID, _ change: (inout Caption) -> Void) {
        guard let trackID = caption(id)?.trackID else { return }
        editCaptions(on: trackID) { captions in
            guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
            change(&captions[index])
        }
    }

    private struct Half {
        var text: String
        var words: [CaptionWord] = []
    }

    private static func splitText(of caption: Caption, at frame: Int64) -> (left: Half, right: Half) {
        let flat = caption.text.replacingOccurrences(of: "\n", with: " ")
        let wordsText = caption.words.map(\.text).joined(separator: " ")
        if !caption.words.isEmpty, normalized(wordsText) == normalized(flat) {
            // Split before the first word that starts at or after the frame (or is mostly after it).
            let index = caption.words.firstIndex { $0.start + $0.duration / 2 >= frame } ?? caption.words.count
            let left = Array(caption.words[..<index])
            let right = Array(caption.words[index...])
            return (Half(text: left.map(\.text).joined(separator: " "), words: left),
                    Half(text: right.map(\.text).joined(separator: " "), words: right))
        }
        // No word timings that match the text: split at the space nearest the time fraction.
        let fraction = Double(frame - caption.start) / Double(max(caption.duration, 1))
        let target = Int((Double(flat.count) * fraction).rounded())
        let spaces = flat.indices.filter { flat[$0] == " " }
        func offset(_ index: String.Index) -> Int { abs(flat.distance(from: flat.startIndex, to: index) - target) }
        guard let split = spaces.min(by: { offset($0) < offset($1) }) else { return (Half(text: flat), Half(text: "")) }
        let left = String(flat[..<split]).trimmingCharacters(in: .whitespaces)
        let right = String(flat[flat.index(after: split)...]).trimmingCharacters(in: .whitespaces)
        return (Half(text: left), Half(text: right))
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
