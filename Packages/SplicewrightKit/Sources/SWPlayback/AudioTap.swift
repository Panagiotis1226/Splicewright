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
    /// Whether the tap's samples are 32-bit floats (anything else passes through untouched).
    private var isFloat = true
    private var chain: AudioEffectChain?
    private var chainClipID: UUID?
    private var scratch: [[Float]] = []
    /// `prepare` can run on another thread while audio is being processed (around seeks); the
    /// effect chain and scratch buffers are only touched while holding this.
    private let stateLock = NSLock()

    init(trackID: UUID, clips: [Clip], rate: FrameRate, levels: MixerLevels, meters: AudioMeters?) {
        self.trackID = trackID
        self.clips = clips
        self.rate = rate
        self.levels = levels
        self.meters = meters
    }

    func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        stateLock.lock()
        defer { stateLock.unlock() }
        sampleRate = format.mSampleRate
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        let channels = max(Int(format.mChannelsPerFrame), 1)
        scratch = Array(repeating: [Float](repeating: 0, count: maxFrames), count: channels)
        chain = nil
        chainClipID = nil
    }

    /// The channels in the buffers as they are on this call (a pointer and the distance between
    /// samples, interleaved or not), and how many frames every buffer really holds, so nothing
    /// is read or written past a buffer's end whatever the format was said to be.
    private static func channels(in buffers: UnsafeMutableAudioBufferListPointer, frames: Int)
        -> (channels: [(UnsafeMutablePointer<Float>, Int)], frames: Int) {
        var channels: [(UnsafeMutablePointer<Float>, Int)] = []
        var available = frames
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let stride = Int(buffer.mNumberChannels)
            available = min(available, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride))
            let base = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<stride { channels.append((base + channel, stride)) }
        }
        return (channels, max(available, 0))
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames requested: Int, start: CMTime) {
        guard requested > 0, isFloat else { return }
        let (channels, frames) = Self.channels(in: UnsafeMutableAudioBufferListPointer(list), frames: requested)
        guard !channels.isEmpty, frames > 0 else { return }
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
        // Never wait on the audio thread: if `prepare` holds the state, skip this buffer's effects.
        guard stateLock.try() else { return }
        defer { stateLock.unlock() }
        let frame = Int64((start.seconds * rate.framesPerSecond).rounded(.down))
        guard let clip = clips.first(where: { $0.range.contains(frame) }), !clip.effects.isEmpty else { return }
        let effects = clip.resolvedAudioEffects(at: clip.sourceTime(atSequenceFrame: frame, rate: rate))
        guard !effects.isEmpty else { return }
        // Buffers not shaped as `prepare` said: start over at their shape (rare, so the allocation is fine).
        if channels.count != scratch.count || frames > (scratch.first?.capacity ?? 0) {
            scratch = Array(repeating: [Float](repeating: 0, count: frames), count: channels.count)
            chain = nil
        }
        if chainClipID != clip.id || chain == nil || chain?.channels != channels.count {
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
