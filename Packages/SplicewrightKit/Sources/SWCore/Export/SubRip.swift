import Foundation

/// SubRip (.srt) and WebVTT (.vtt) caption files.
public enum SubRip {
    public enum Format: String, Sendable, Hashable, Codable, CaseIterable {
        case srt, vtt

        public var fileExtension: String { rawValue }
        public var displayName: String { self == .srt ? "SubRip (.srt)" : "WebVTT (.vtt)" }
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case noCaptions

        public var errorDescription: String? { "No captions were found in the file." }
    }

    /// Captions as a file. With `range`, only captions inside it are written, clipped to it,
    /// with times counted from its start (matching an In-to-Out export).
    public static func write(_ captions: [Caption], rate: FrameRate, range: FrameRange? = nil,
                             format: Format = .srt) -> String {
        let offset = range?.start ?? 0
        var cues: [(start: Int64, end: Int64, text: String)] = []
        for caption in captions.sorted(by: { $0.start < $1.start }) {
            let text = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var start = caption.start
            var end = caption.end
            if let range {
                start = max(start, range.start)
                end = min(end, range.end)
                guard end > start else { continue }
            }
            cues.append((start - offset, end - offset, text))
        }
        var lines: [String] = format == .vtt ? ["WEBVTT", ""] : []
        for (number, cue) in cues.enumerated() {
            if format == .srt { lines.append(String(number + 1)) }
            lines.append("\(timestamp(cue.start, rate, format)) --> \(timestamp(cue.end, rate, format))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Reads .srt or .vtt text into captions at `rate`, offset by `startFrame`.
    public static func parse(_ text: String, rate: FrameRate, startFrame: Int64 = 0) throws -> [Caption] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var captions: [Caption] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]),
                  let end = seconds(parts[1].split(separator: " ").first.map(String.init) ?? "") else { continue }
            let body = lines[(timingIndex + 1)...]
                .map { strippingTags($0) }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
            guard !body.isEmpty else { continue }
            let startFrame = startFrame + frame(start, rate)
            let endFrame = startFrame + max(1, frame(end, rate) - frame(start, rate))
            captions.append(Caption(start: startFrame, duration: endFrame - startFrame, text: body))
        }
        guard !captions.isEmpty else { throw ParseError.noCaptions }
        return captions.sorted { $0.start < $1.start }
    }

    /// `HH:MM:SS,mmm` (SRT) or `HH:MM:SS.mmm` (VTT) for a frame.
    public static func timestamp(_ frame: Int64, _ rate: FrameRate, _ format: Format = .srt) -> String {
        let milliseconds = Int64((RationalTime(frames: frame, rate: rate).seconds * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let secs = milliseconds / 1000 % 60
        let millis = milliseconds % 1000
        let separator = format == .srt ? "," : "."
        return String(format: "%02lld:%02lld:%02lld", hours, minutes, secs) + separator + String(format: "%03lld", millis)
    }

    /// Seconds from `HH:MM:SS,mmm`, `HH:MM:SS.mmm` or `MM:SS.mmm`.
    static func seconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fields = trimmed.split(separator: ":").map(String.init)
        guard (2...3).contains(fields.count) else { return nil }
        var total = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func frame(_ seconds: Double, _ rate: FrameRate) -> Int64 {
        Int64((seconds * rate.framesPerSecond).rounded())
    }

    /// Removes simple markup such as `<i>`, `<b>`, `<font ...>` and VTT voice tags.
    static func strippingTags(_ line: String) -> String {
        var result = ""
        var inTag = false
        for character in line {
            if character == "<" { inTag = true } else if character == ">" { inTag = false } else if !inTag {
                result.append(character)
            }
        }
        return result
    }
}
