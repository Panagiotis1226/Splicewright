import Foundation

/// Turns recognized words into readable captions, following common subtitle rules: break at
/// the end of a sentence or a pause, keep within the line limits, stay on screen long enough
/// to read, and don't flash off for a moment between two captions.
public enum CaptionSegmenter {
    /// A pause longer than this starts a new caption.
    public static let pauseSeconds = 0.7
    public static let minimumSeconds = 0.8
    public static let maximumSeconds = 7.0
    /// Gaps shorter than this between captions are closed.
    public static let closeGapFrames: Int64 = 3

    public static func captions(from words: [TimedWord], rate: FrameRate, style: CaptionStyle) -> [Caption] {
        let words = words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        var groups: [[TimedWord]] = []
        var current: [TimedWord] = []
        for word in words {
            if let first = current.first, let last = current.last {
                let gap = word.start - last.end
                let length = joinedLength(current + [word])
                let duration = word.end - first.start
                if gap > pauseSeconds || length > style.maxCharacters || duration > maximumSeconds {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
            if endsSentence(word.text) || (endsClause(word.text) && joinedLength(current) > style.maxCharacters / 2) {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }

        var captions = groups.map { group -> Caption in
            let captionWords = group.map { word -> CaptionWord in
                let start = frame(word.start, rate)
                return CaptionWord(text: word.text, start: start, duration: max(1, frame(word.end, rate) - start))
            }
            let start = captionWords.first?.start ?? 0
            let end = max(captionWords.last?.end ?? start + 1, start + 1)
            return Caption(start: start, duration: end - start, text: layout(group.map(\.text), style: style),
                           words: captionWords)
        }
        let minimum = max(1, frame(minimumSeconds, rate))
        for index in captions.indices {
            let next = index + 1 < captions.count ? captions[index + 1].start : Int64.max
            var end = max(captions[index].end, captions[index].start + minimum)
            if next - end < closeGapFrames { end = next }
            end = min(end, next)
            captions[index].duration = max(1, end - captions[index].start)
        }
        return captions
    }

    /// Re-splits a track's captions with a (new) style, keeping their words' timing. Captions
    /// without words (typed or imported) are kept as they are.
    public static func resplit(_ captions: [Caption], rate: FrameRate, style: CaptionStyle) -> [Caption] {
        var result: [Caption] = []
        var pending: [TimedWord] = []
        func flush() {
            result += self.captions(from: pending, rate: rate, style: style)
            pending = []
        }
        for caption in captions {
            if caption.words.isEmpty {
                flush()
                result.append(caption)
            } else {
                pending += caption.words.map {
                    TimedWord(text: $0.text, start: RationalTime(frames: $0.start, rate: rate).seconds,
                              duration: RationalTime(frames: $0.duration, rate: rate).seconds)
                }
            }
        }
        flush()
        return result
    }

    /// Words on one or more lines: one line when it fits, else balanced lines.
    public static func layout(_ words: [String], style: CaptionStyle) -> String {
        let text = words.joined(separator: " ")
        guard style.maxLines > 1, text.count > style.maxCharactersPerLine, words.count > 1 else { return text }
        // Two lines, split where they're closest in length (a common subtitle convention).
        var best = 1
        var bestScore = Int.max
        for split in 1..<words.count {
            let top = words[..<split].joined(separator: " ").count
            let bottom = words[split...].joined(separator: " ").count
            var score = abs(top - bottom)
            if max(top, bottom) > style.maxCharactersPerLine { score += 1000 }
            if endsClause(words[split - 1]) || endsSentence(words[split - 1]) { score -= 4 }
            if score < bestScore {
                bestScore = score
                best = split
            }
        }
        return words[..<best].joined(separator: " ") + "\n" + words[best...].joined(separator: " ")
    }

    static func joinedLength(_ words: [TimedWord]) -> Int {
        words.reduce(0) { $0 + $1.text.count } + max(0, words.count - 1)
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)")).last else { return false }
        return ".?!…。？！".contains(last)
    }

    static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",;:—、，".contains(last)
    }

    static func frame(_ seconds: Double, _ rate: FrameRate) -> Int64 {
        Int64((seconds * rate.framesPerSecond).rounded())
    }
}
