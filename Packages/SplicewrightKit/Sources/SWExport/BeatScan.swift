import AVFoundation
import SWCore
import SWMedia
import SWPlayback

/// Detect Beats' analysis: the sequence's mix over `frames` as it plays (or only the chosen
/// audio clips), through a `BeatDetector`.
public enum BeatScan {
    /// The tempo and the beats, as sequence frames.
    public static func beats(in sequence: EditSequence, project: Project, frames: FrameRange, settings: BeatSettings,
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws
        -> (bpm: Double, frames: [Int64]) {
        let output = await CompositionBuilder(renderSize: CGSize(width: 320, height: 180))
            .build(sequence, project: project, cache: MediaAssetCache())
        let tracks = try await output.composition.loadTracks(withMediaType: .audio)
            .filter { track in track.segments.contains { !$0.isEmpty } }
        guard !tracks.isEmpty else { return (0, []) }
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
        let analysis = try await Task.detached { () throws -> BeatAnalysis in
            guard box.reader.startReading() else { throw box.reader.error ?? ExportError.message("Couldn't read the audio.") }
            var detector = BeatDetector(sampleRate: 48_000)
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
            return detector.analysis(settings)
        }.value
        return (analysis.bpm, EditSequence.beatFrames(analysis.beats, from: frames.start, rate: rate))
    }

    private struct Box: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderOutput
    }
}
