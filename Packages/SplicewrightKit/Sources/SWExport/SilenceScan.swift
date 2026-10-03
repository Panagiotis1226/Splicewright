import AVFoundation
import SWCore
import SWMedia
import SWPlayback

/// Remove Silence's analysis: the sequence's mix over `frames`, as it plays (faders and audio
/// effects included), through a `SilenceDetector`.
public enum SilenceScan {
    /// The pauses, as sequence frame ranges.
    public static func pauses(in sequence: EditSequence, project: Project, frames: FrameRange, settings: SilenceSettings,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [FrameRange] {
        let output = await CompositionBuilder(renderSize: CGSize(width: 320, height: 180))
            .build(sequence, project: project, cache: MediaAssetCache())
        let tracks = try await output.composition.loadTracks(withMediaType: .audio)
            .filter { track in track.segments.contains { !$0.isEmpty } }
        // No audio at all: the whole range is quiet.
        guard !tracks.isEmpty else { return frames.isEmpty ? [] : [frames] }
        let rate = sequence.rate
        let range = CMTimeRange(start: RationalTime(frames: frames.start, rate: rate).cmTime,
                                end: RationalTime(frames: frames.end, rate: rate).cmTime)
        let reader = try AVAssetReader(asset: output.composition)
        reader.timeRange = range
        let mix = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: ExportAudio.readerSettings)
        mix.audioMix = output.audioMix
        mix.audioTimePitchAlgorithm = output.audioTimePitchAlgorithm
        guard reader.canAdd(mix) else { throw ExportError.message("Couldn't read the sequence's audio.") }
        reader.add(mix)
        let box = Box(reader: reader, output: mix)
        let silences = try await Task.detached { () throws -> [ClosedRange<Double>] in
            guard box.reader.startReading() else { throw box.reader.error ?? ExportError.message("Couldn't read the audio.") }
            var detector = SilenceDetector(sampleRate: 48_000, settings: settings)
            let duration = max(range.duration.seconds, 1e-6)
            while !Task.isCancelled, let sample = box.output.copyNextSampleBuffer() {
                InterleavedAudio.withChannels(of: sample) { detector.process($0) }
                progress(min(1, detector.duration / duration))
            }
            if Task.isCancelled {
                box.reader.cancelReading()
                throw CancellationError()
            }
            guard box.reader.status == .completed else { throw box.reader.error ?? CancellationError() }
            return detector.silences()
        }.value
        return EditSequence.frameRanges(silences, from: frames.start, rate: rate)
    }

    private struct Box: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderOutput
    }
}
