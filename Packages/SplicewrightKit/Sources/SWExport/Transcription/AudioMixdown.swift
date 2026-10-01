import AVFoundation
import SWCore
import SWMedia
import SWPlayback

/// Renders a sequence's audio, exactly as it plays (gain, fades, volume keyframes, mute and
/// solo), to a 16 kHz mono file for speech recognition.
public enum AudioMixdown {
    public enum Failure: Error, LocalizedError, Equatable {
        case noAudio
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noAudio: return "The sequence has no audio to transcribe."
            case .failed(let reason): return "Couldn't read the sequence's audio: \(reason)"
            }
        }
    }

    public static let sampleRate = 16_000.0

    /// Writes `range` of the sequence's mix to a temporary .caf and returns its URL.
    public static func render(_ sequence: EditSequence, project: Project, range: FrameRange) async throws -> URL {
        let output = await CompositionBuilder().build(sequence, project: project, cache: MediaAssetCache())
        let tracks = try await output.composition.loadTracks(withMediaType: .audio)
            .filter { track in track.segments.contains { !$0.isEmpty } }
        guard !tracks.isEmpty else { throw Failure.noAudio }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: output.composition) } catch {
            throw Failure.failed(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let mix = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        mix.audioMix = output.audioMix
        guard reader.canAdd(mix) else { throw Failure.failed("unsupported audio") }
        reader.add(mix)
        reader.timeRange = CMTimeRange(start: RationalTime(frames: range.start, rate: sequence.rate).cmTime,
                                       end: RationalTime(frames: range.end, rate: sequence.rate).cmTime)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                         interleaved: false) else { throw Failure.failed("no audio format") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("splicewright-mix-\(UUID().uuidString).caf")
        let file: AVAudioFile
        do { file = try AVAudioFile(forWriting: url, settings: format.settings) } catch {
            throw Failure.failed(error.localizedDescription)
        }
        guard reader.startReading() else { throw Failure.failed(reader.error?.localizedDescription ?? "unknown error") }
        var wroteSamples = false
        while let sample = mix.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                                    destination: channel)
            guard status == kCMBlockBufferNoErr else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            do { try file.write(from: buffer) } catch { throw Failure.failed(error.localizedDescription) }
            wroteSamples = true
        }
        if reader.status == .failed { throw Failure.failed(reader.error?.localizedDescription ?? "unknown error") }
        guard wroteSamples else { throw Failure.noAudio }
        return url
    }
}
