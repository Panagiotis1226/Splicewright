import AppKit
import SWCore

/// Geometry of the timeline: ruler on top, track headers on the left, video tracks
/// (Vn at the top … V1) above audio tracks (A1 … An), like Premiere.
enum TimelineLayout {
    static let rulerHeight: CGFloat = 28
    static let headerWidth: CGFloat = 176
    static let trackHeight: CGFloat = 46
    static let kindGap: CGFloat = 6
    static let edgeGrabWidth: CGFloat = 6
    /// Last measured lane width, so keyboard zoom-to-fit knows the visible width.
    static var lastLaneWidth: CGFloat = 800

    struct Row {
        var trackID: UUID
        var kind: TrackKind
        var index: Int
        var name: String
        var rect: CGRect
    }

    static let captionHeight: CGFloat = 30

    /// A subtitle track's row, above the video tracks.
    struct CaptionRow {
        var trackID: UUID
        var index: Int
        var name: String
        var rect: CGRect
    }

    /// Caption rows, top down (the newest track on top), in content coordinates.
    static func captionRows(for sequence: EditSequence, width: CGFloat) -> [CaptionRow] {
        var y = rulerHeight
        return sequence.captionTracks.enumerated().reversed().map { index, track in
            defer { y += captionHeight + 1 }
            return CaptionRow(trackID: track.id, index: index, name: "ST\(index + 1)",
                              rect: CGRect(x: 0, y: y, width: width, height: captionHeight))
        }
    }

    /// Space the caption rows take, including the gap below them.
    static func captionsHeight(for sequence: EditSequence) -> CGFloat {
        sequence.captionTracks.isEmpty ? 0 : CGFloat(sequence.captionTracks.count) * (captionHeight + 1) + kindGap
    }

    /// Rows in display order, in content coordinates (before vertical scrolling).
    static func rows(for sequence: EditSequence, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var y = rulerHeight + captionsHeight(for: sequence)
        for (index, track) in sequence.videoTracks.enumerated().reversed() {
            rows.append(Row(trackID: track.id, kind: .video, index: index, name: "V\(index + 1)",
                            rect: CGRect(x: 0, y: y, width: width, height: trackHeight)))
            y += trackHeight + 1
        }
        y += kindGap
        for (index, track) in sequence.audioTracks.enumerated() {
            rows.append(Row(trackID: track.id, kind: .audio, index: index, name: "A\(index + 1)",
                            rect: CGRect(x: 0, y: y, width: width, height: trackHeight)))
            y += trackHeight + 1
        }
        return rows
    }

    static func contentHeight(for sequence: EditSequence) -> CGFloat {
        let tracks = CGFloat(sequence.videoTracks.count + sequence.audioTracks.count)
        return rulerHeight + captionsHeight(for: sequence) + tracks * (trackHeight + 1) + kindGap
    }

    /// Tick spacing for the ruler: a "nice" number of frames at least `minimumPoints` apart.
    static func tickStep(pixelsPerFrame: CGFloat, rate: FrameRate, minimumPoints: CGFloat = 90) -> Int64 {
        let fps = Int64(rate.timecodeBase)
        let seconds: [Int64] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let candidates: [Int64] = [1, 2, 5, 10, fps / 2] + seconds.map { $0 * fps }
        for step in candidates where step > 0 && CGFloat(step) * pixelsPerFrame >= minimumPoints {
            return step
        }
        return 3600 * fps * 4
    }

    /// Header buttons, left to right after the track name.
    enum HeaderControl: CaseIterable {
        case target, lock, syncLock, output, solo

        static func controls(for kind: TrackKind) -> [HeaderControl] {
            kind == .video ? [.target, .lock, .syncLock, .output] : [.target, .lock, .syncLock, .output, .solo]
        }

        func rect(in row: CGRect, kind: TrackKind) -> CGRect {
            guard let position = Self.controls(for: kind).firstIndex(of: self) else { return .zero }
            let size: CGFloat = 20
            let x: CGFloat = self == .target ? 8 : 42 + CGFloat(position - 1) * 26
            let width = self == .target ? 28 : size
            return CGRect(x: x, y: row.midY - size / 2, width: width, height: size)
        }
    }
}
