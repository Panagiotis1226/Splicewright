import AVFoundation
import MediaToolbox
import SWCore

/// The Audio Track Mixer's settings for one composition, read by its taps on the audio thread.
/// Moving a fader updates this in place, so playback doesn't need a rebuild.
public final class MixerLevels: @unchecked Sendable {
    private struct TrackGains {
        var left: Float
        var right: Float
    }

    private let lock = NSLock()
    private var tracks: [UUID: TrackGains] = [:]

    public init(_ sequence: EditSequence) {
        update(from: sequence)
    }

    public func update(from sequence: EditSequence) {
        let mix = Mixer.gain(dB: sequence.mixVolumeDB)
        var gains: [UUID: TrackGains] = [:]
        for track in sequence.audioTracks {
            let volume = Mixer.gain(dB: track.volumeDB) * mix
            let balance = Mixer.balance(track.pan)
            gains[track.id] = TrackGains(left: Float(volume * balance.left), right: Float(volume * balance.right))
        }
        lock.lock()
        tracks = gains
        lock.unlock()
    }

    /// Fader × pan × Mix fader, for the left and right channels.
    func gains(for trackID: UUID) -> (left: Float, right: Float) {
        lock.lock()
        defer { lock.unlock() }
        let gains = tracks[trackID] ?? TrackGains(left: 1, right: 1)
        return (gains.left, gains.right)
    }
}

/// Peak levels measured by the taps (after each track's fader), collected until read.
public final class AudioMeters: @unchecked Sendable {
    private let lock = NSLock()
    private var peaks: [UUID: [Float]] = [:]

    public init() {}

    func record(_ trackID: UUID, peaks values: [Float]) {
        lock.lock()
        let current = peaks[trackID] ?? []
        peaks[trackID] = values.indices.map { max($0 < current.count ? current[$0] : 0, values[$0]) }
        lock.unlock()
    }

    /// The highest left/right peaks per track since the last read, and an estimate for the Mix
    /// (tracks add up as uncorrelated signals would: the root of the summed squares).
    public func read() -> (tracks: [UUID: [Float]], mix: [Float]) {
        lock.lock()
        let tracks = peaks
        peaks = [:]
        lock.unlock()
        var energy: [Float] = [0, 0]
        for levels in tracks.values {
            for channel in 0..<2 {
                let level = levels.isEmpty ? 0 : levels[min(channel, levels.count - 1)]
                energy[channel] += level * level
            }
        }
        return (tracks, energy.map { min(1.5, $0.squareRoot()) })
    }
}

/// What one tap needs: the sequence track it belongs to and the clips placed on its
/// composition track (for their audio effects).
final class TapContext: @unchecked Sendable {
    let trackID: UUID
    let clips: [Clip]
    let rate: FrameRate
    let levels: MixerLevels
    let meters: AudioMeters?

    private var sampleRate = 48_000.0
    private var channelCount = 2
    private var interleaved = false
    private var chain: AudioEffectChain?
    private var chainClipID: UUID?
    private var scratch: [[Float]] = []

    init(trackID: UUID, clips: [Clip], rate: FrameRate, levels: MixerLevels, meters: AudioMeters?) {
        self.trackID = trackID
        self.clips = clips
        self.rate = rate
        self.levels = levels
        self.meters = meters
    }

    func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        channelCount = Int(format.mChannelsPerFrame)
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        scratch = Array(repeating: [Float](repeating: 0, count: maxFrames), count: max(channelCount, 1))
        chain = nil
        chainClipID = nil
    }

    /// Float samples of one channel: a pointer and the distance between samples.
    private func channel(_ index: Int, in buffers: UnsafeMutableAudioBufferListPointer)
        -> (UnsafeMutablePointer<Float>, Int)? {
        if interleaved {
            guard let data = buffers.first?.mData else { return nil }
            return (data.assumingMemoryBound(to: Float.self) + index, channelCount)
        }
        guard index < buffers.count, let data = buffers[index].mData else { return nil }
        return (data.assumingMemoryBound(to: Float.self), 1)
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: CMTime) {
        guard frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let channels = (0..<channelCount).compactMap { channel($0, in: buffers) }
        guard !channels.isEmpty else { return }
        applyEffects(channels, frames: frames, start: start)

        // Fader, pan and the Mix fader, then the meter.
        let gains = levels.gains(for: trackID)
        var peaks = [Float](repeating: 0, count: min(channels.count, 2))
        for (index, (pointer, stride)) in channels.enumerated() {
            let gain = channels.count == 1 ? (gains.left + gains.right) / 2 : (index == 0 ? gains.left : gains.right)
            var peak: Float = 0
            for frame in 0..<frames {
                let value = pointer[frame * stride] * gain
                pointer[frame * stride] = value
                peak = max(peak, abs(value))
            }
            if index < peaks.count { peaks[index] = peak }
        }
        meters?.record(trackID, peaks: peaks)
    }

    /// Runs the active clip's audio effects, keeping their state while that clip plays.
    private func applyEffects(_ channels: [(UnsafeMutablePointer<Float>, Int)], frames: Int, start: CMTime) {
        guard start.isNumeric else { return }
        let frame = Int64((start.seconds * rate.framesPerSecond).rounded(.down))
        guard let clip = clips.first(where: { $0.range.contains(frame) }), !clip.effects.isEmpty else { return }
        let effects = clip.resolvedAudioEffects(at: clip.sourceTime(atSequenceFrame: frame, rate: rate))
        guard !effects.isEmpty, channels.count == scratch.count, frames <= scratch[0].capacity else { return }
        if chainClipID != clip.id || chain == nil {
            chain = AudioEffectChain(sampleRate: sampleRate, channels: channels.count)
            chainClipID = clip.id
        }
        // Move the arrays out and back (rather than copying them) so the audio thread reuses
        // their storage instead of allocating.
        var buffers = scratch
        scratch = []
        for (index, (pointer, stride)) in channels.enumerated() {
            buffers[index].removeAll(keepingCapacity: true)
            for frame in 0..<frames { buffers[index].append(pointer[frame * stride]) }
        }
        chain?.process(effects, &buffers)
        for (index, (pointer, stride)) in channels.enumerated() {
            for frame in 0..<frames { pointer[frame * stride] = buffers[index][frame] }
        }
        scratch = buffers
    }

    private static func context(_ tap: MTAudioProcessingTap) -> TapContext {
        Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }

    /// An audio processing tap running `context` (it keeps the context alive until it's released).
    static func makeTap(_ context: TapContext) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, maxFrames, format in
                TapContext.context(tap).prepare(maxFrames: Int(maxFrames), format: format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange()
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr
                else { return }
                TapContext.context(tap).process(bufferList, frames: Int(framesOut.pointee), start: range.start)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            // The tap never took ownership.
            Unmanaged.passUnretained(context).release()
            return nil
        }
        return tap
    }
}
