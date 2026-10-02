import AVFoundation
import SWCore
import SWMedia
import SWPlayback

extension SmokeTestDriver {
    static func checkCache(_ report: inout Report) {
        let manager = CacheManager.shared
        report.cacheBytes = manager.usage().values.reduce(0) { $0 + $1.bytes }
        manager.delete([.thumbnails])
        report.thumbnailCacheCleared = manager.usage()[.thumbnails]?.files == 0
    }

    /// What the export's audio mix sounds like over `frames`: read the way the loudness pass
    /// reads it, from the range's start and from zero, and without the clips' audio effects.
    /// For the report when the export measured silence.
    static func mixDetail(_ sequence: EditSequence, project: Project, frames: Range<Int64>) async -> String {
        var plain = sequence
        for track in plain.audioTracks {
            plain.updateClipProperties(Set(track.clips.map(\.id))) { $0.effects = [] }
        }
        var parts: [String] = []
        for (name, candidate, from) in [("effects", sequence, frames.lowerBound), ("effects from 0", sequence, Int64(0)),
                                        ("no effects", plain, frames.lowerBound)] {
            parts.append("\(name): " + (await readMix(candidate, project: project, frames: from..<frames.upperBound)))
        }
        return parts.joined(separator: " | ")
    }

    private static func readMix(_ sequence: EditSequence, project: Project, frames: Range<Int64>) async -> String {
        let output = await CompositionBuilder(renderSize: CGSize(width: 320, height: 180))
            .build(sequence, project: project, cache: MediaAssetCache())
        guard let tracks = try? await output.composition.loadTracks(withMediaType: .audio),
              let reader = try? AVAssetReader(asset: output.composition) else { return "no reader" }
        let rate = sequence.rate
        reader.timeRange = CMTimeRange(start: RationalTime(frames: frames.lowerBound, rate: rate).cmTime,
                                       end: RationalTime(frames: frames.upperBound, rate: rate).cmTime)
        let mix = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        mix.audioMix = output.audioMix
        mix.audioTimePitchAlgorithm = output.audioTimePitchAlgorithm
        guard reader.canAdd(mix) else { return "can't add the mix" }
        reader.add(mix)
        guard reader.startReading() else { return "start: \(String(describing: reader.error))" }
        let started = Date()
        var (buffers, samples, nonFinite, zeros) = (0, 0, 0, 0)
        var peak: Float = 0
        while let sample = mix.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = values.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            buffers += 1
            samples += values.count
            for value in values {
                if !value.isFinite { nonFinite += 1 } else if value == 0 { zeros += 1 } else { peak = max(peak, abs(value)) }
            }
        }
        let meters = output.meters?.read().tracks.values.map { $0.map { String(format: "%.3f", $0) } } ?? []
        return "\(audioTrackSummary(tracks)) \(buffers) buffers, \(samples) samples, \(zeros) zero, \(nonFinite) non-finite, "
            + "peak \(peak), \(String(format: "%.2f", Date().timeIntervalSince(started))) s, status \(reader.status.rawValue), "
            + "meters \(meters)"
    }

    private static func audioTrackSummary(_ tracks: [AVCompositionTrack]) -> String {
        "\(tracks.count) tracks (\(tracks.map { $0.segments.filter { !$0.isEmpty }.count }) segments):"
    }
}
