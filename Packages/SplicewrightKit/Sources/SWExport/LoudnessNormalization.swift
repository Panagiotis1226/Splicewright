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
    static func measure(_ output: CompositionOutput, range: CMTimeRange,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessMeter? {
        let tracks = try await output.composition.loadTracks(withMediaType: .audio)
            .filter { track in track.segments.contains { !$0.isEmpty } }
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: output.composition)
        reader.timeRange = range
        let mix = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: ExportAudio.readerSettings)
        mix.audioMix = output.audioMix
        mix.audioTimePitchAlgorithm = output.audioTimePitchAlgorithm
        guard reader.canAdd(mix) else { return nil }
        reader.add(mix)
        let box = ReaderBox(reader: reader, output: mix)
        // Reading blocks, so keep it off the main actor.
        return try await Task.detached {
            guard box.reader.startReading() else { throw box.reader.error ?? ExportError.message("Couldn't read the audio.") }
            var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
            let duration = max(range.duration.seconds, 1e-6)
            while !Task.isCancelled, let sample = box.output.copyNextSampleBuffer() {
                InterleavedAudio.withChannels(of: sample) { channels in meter.process(channels) }
                progress((CMSampleBufferGetPresentationTimeStamp(sample) - range.start).seconds / duration)
            }
            if Task.isCancelled { box.reader.cancelReading() }
            guard box.reader.status == .completed else {
                throw box.reader.error ?? CancellationError()
            }
            return meter
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

/// The export reader's audio: 32-bit float, interleaved stereo.
enum InterleavedAudio {
    private static func samples(of sample: CMSampleBuffer) -> UnsafeMutableBufferPointer<Float>? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) else { return nil }
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { return nil }
        let count = length / MemoryLayout<Float>.size
        return UnsafeMutableBufferPointer(start: UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: Float.self),
                                          count: count)
    }

    static func withChannels(of sample: CMSampleBuffer, _ body: ([[Float]]) -> Void) {
        guard let data = samples(of: sample) else { return }
        let frames = data.count / 2
        body([(0..<frames).map { data[$0 * 2] }, (0..<frames).map { data[$0 * 2 + 1] }])
    }

    static func modifyChannels(of sample: CMSampleBuffer, _ body: (inout [[Float]]) -> Void) {
        guard let data = samples(of: sample) else { return }
        let frames = data.count / 2
        var channels = [(0..<frames).map { data[$0 * 2] }, (0..<frames).map { data[$0 * 2 + 1] }]
        body(&channels)
        for frame in 0..<frames {
            data[frame * 2] = channels[0][frame]
            data[frame * 2 + 1] = channels[1][frame]
        }
    }
}
