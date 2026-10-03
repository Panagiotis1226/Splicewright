import AVFoundation
import SWCore
import SWPlayback

/// What normalization did, for the finished export sheet and the log.
public struct LoudnessResult: Sendable, Equatable {
    /// Integrated loudness of the mix before normalizing, in LUFS.
    public var measured: Double
    public var target: Double
    public var gainDB: Double
    /// Whether peaks were limited to stay under the true-peak ceiling.
    public var limited: Bool

    public var summary: String {
        let gain = gainDB >= 0 ? "+\(Self.format(gainDB))" : Self.format(gainDB)
        return "Loudness: measured \(Self.format(measured)) LUFS → \(Self.format(target)) LUFS (\(gain) dB"
            + (limited ? ", peaks limited to \(Self.format(LoudnessTarget.truePeakCeiling)) dBTP)" : ")")
    }

    private static func format(_ value: Double) -> String { String((value * 10).rounded() / 10) }
}

/// Pass 1: the integrated loudness and true peak of the exported range's mix.
enum LoudnessScan {
    /// The meter, and what was read (for the log when it comes out silent).
    struct Measured: @unchecked Sendable {
        var meter: LoudnessMeter?
        var note: String
    }

    static func measure(_ output: CompositionOutput, range: CMTimeRange,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Measured {
        let tracks = try await output.composition.loadTracks(withMediaType: .audio)
            .filter { track in track.segments.contains { !$0.isEmpty } }
        guard !tracks.isEmpty else { return Measured(meter: nil, note: "no audio tracks") }
        let reader = try AVAssetReader(asset: output.composition)
        reader.timeRange = range
        let mix = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: ExportAudio.readerSettings)
        mix.audioMix = output.audioMix
        mix.audioTimePitchAlgorithm = output.audioTimePitchAlgorithm
        guard reader.canAdd(mix) else { return Measured(meter: nil, note: "the mix couldn't be read") }
        reader.add(mix)
        let box = ReaderBox(reader: reader, output: mix)
        let trackCount = tracks.count
        // Reading blocks, so keep it off the main actor.
        return try await Task.detached {
            guard box.reader.startReading() else { throw box.reader.error ?? ExportError.message("Couldn't read the audio.") }
            var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
            let duration = max(range.duration.seconds, 1e-6)
            var (buffers, unread, frames) = (0, 0, 0)
            var peak: Float = 0
            while !Task.isCancelled, let sample = box.output.copyNextSampleBuffer() {
                buffers += 1
                var read = false
                InterleavedAudio.withChannels(of: sample) { channels in
                    read = true
                    frames += channels.first?.count ?? 0
                    for channel in channels { peak = channel.reduce(peak) { max($0, abs($1)) } }
                    meter.process(channels)
                }
                if !read { unread += 1 }
                progress((CMSampleBufferGetPresentationTimeStamp(sample) - range.start).seconds / duration)
            }
            if Task.isCancelled { box.reader.cancelReading() }
            guard box.reader.status == .completed else {
                throw box.reader.error ?? CancellationError()
            }
            let note = "\(trackCount) tracks, \(buffers) buffers (\(unread) unreadable), \(frames) frames, "
                + "peak \(peak), range \(range.start.seconds)–\(range.end.seconds) s"
            return Measured(meter: meter, note: note)
        }.value
    }

    private struct ReaderBox: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderOutput
    }
}

/// Pass 2: applies the normalization gain to each audio buffer before it's written, with a
/// limiter when the louder peaks would go over the ceiling.
final class LoudnessGain: @unchecked Sendable {
    private let gain: Float
    private var limiter: HardLimiter?

    init(gainDB: Double, limit: Bool) {
        gain = Float(pow(10, gainDB / 20))
        // Half a dB under the true-peak ceiling covers the overs between samples and from encoding.
        limiter = limit ? HardLimiter(ceilingDB: LoudnessTarget.truePeakCeiling - 0.5, sampleRate: 48_000) : nil
    }

    /// Called on the audio pump's queue only.
    func apply(to sample: CMSampleBuffer) {
        InterleavedAudio.modifyChannels(of: sample) { channels in
            for index in channels.indices {
                for frame in channels[index].indices { channels[index][frame] *= gain }
            }
            limiter?.process(&channels)
        }
    }
}

/// The export reader's audio: 32-bit float, interleaved stereo. The samples are copied out and
/// back, since a buffer's data can come in more than one piece.
enum InterleavedAudio {
    private static func samples(of block: CMBlockBuffer) -> [Float]? {
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        var values = [Float](repeating: 0, count: count)
        let status = values.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? values : nil
    }

    /// Left and right as separate arrays.
    private static func split(_ data: [Float]) -> [[Float]] {
        let frames = data.count / 2
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            left[frame] = data[frame * 2]
            right[frame] = data[frame * 2 + 1]
        }
        return [left, right]
    }

    static func withChannels(of sample: CMSampleBuffer, _ body: ([[Float]]) -> Void) {
        guard let block = CMSampleBufferGetDataBuffer(sample), let data = samples(of: block) else { return }
        body(split(data))
    }

    static func modifyChannels(of sample: CMSampleBuffer, _ body: (inout [[Float]]) -> Void) {
        guard let block = CMSampleBufferGetDataBuffer(sample), var data = samples(of: block) else { return }
        var channels = split(data)
        body(&channels)
        for frame in 0..<(data.count / 2) {
            data[frame * 2] = channels[0][frame]
            data[frame * 2 + 1] = channels[1][frame]
        }
        _ = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: raw.count)
        }
    }
}
