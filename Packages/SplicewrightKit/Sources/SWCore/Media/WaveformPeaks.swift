import Foundation

/// Down-sampled audio peaks used to draw waveforms.
///
/// Each channel stores one byte per bucket: the bucket's peak absolute sample
/// value quantized to 0...255. About 200 buckets per second keeps an hour of
/// stereo audio around 1.4 MB.
public struct WaveformPeaks: Sendable, Hashable, Codable {
    public var sampleRate: Double
    public var samplesPerBucket: Int
    public var channels: [Data]

    public init(sampleRate: Double, samplesPerBucket: Int, channels: [Data]) {
        self.sampleRate = sampleRate
        self.samplesPerBucket = samplesPerBucket
        self.channels = channels
    }

    public static func bucketSize(forSampleRate sampleRate: Double) -> Int {
        max(1, Int(sampleRate / 200))
    }

    public var bucketCount: Int { channels.first?.count ?? 0 }
    public var bucketsPerSecond: Double { sampleRate / Double(samplesPerBucket) }

    /// Peak (0...1) across all channels for the buckets covering `[start, end)` seconds.
    public func peak(from start: Double, to end: Double) -> Float {
        channels.indices.map { channelPeak($0, from: start, to: end) }.max() ?? 0
    }

    /// Peak (0...1) of one channel for the buckets covering `[start, end)` seconds.
    public func channelPeak(_ channel: Int, from start: Double, to end: Double) -> Float {
        guard channels.indices.contains(channel), bucketCount > 0, end > start else { return 0 }
        let first = max(0, Int(start * bucketsPerSecond))
        let last = min(bucketCount, max(first + 1, Int((end * bucketsPerSecond).rounded(.up))))
        guard first < last else { return 0 }
        let data = channels[channel]
        var peak: UInt8 = 0
        for index in first..<last where data[data.startIndex + index] > peak {
            peak = data[data.startIndex + index]
        }
        return Float(peak) / 255
    }
}

/// Builds `WaveformPeaks` incrementally from interleaved Float32 PCM.
public struct PeakAccumulator: Sendable {
    public let channelCount: Int
    public let samplesPerBucket: Int
    public let sampleRate: Double

    private var channels: [[UInt8]]
    private var currentPeaks: [Float]
    private var framesInBucket = 0

    public init(channelCount: Int, sampleRate: Double, samplesPerBucket: Int? = nil) {
        precondition(channelCount > 0)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.samplesPerBucket = samplesPerBucket ?? WaveformPeaks.bucketSize(forSampleRate: sampleRate)
        channels = Array(repeating: [], count: channelCount)
        currentPeaks = Array(repeating: 0, count: channelCount)
    }

    /// Appends interleaved samples (`frame0ch0, frame0ch1, frame1ch0, ...`).
    public mutating func append(interleaved samples: UnsafeBufferPointer<Float>) {
        let frames = samples.count / channelCount
        var index = 0
        for _ in 0..<frames {
            for channel in 0..<channelCount {
                let magnitude = abs(samples[index])
                if magnitude > currentPeaks[channel] { currentPeaks[channel] = magnitude }
                index += 1
            }
            framesInBucket += 1
            if framesInBucket == samplesPerBucket { flushBucket() }
        }
    }

    public mutating func append(interleaved samples: [Float]) {
        samples.withUnsafeBufferPointer { append(interleaved: $0) }
    }

    public mutating func finish() -> WaveformPeaks {
        if framesInBucket > 0 { flushBucket() }
        return WaveformPeaks(sampleRate: sampleRate, samplesPerBucket: samplesPerBucket,
                             channels: channels.map { Data($0) })
    }

    private mutating func flushBucket() {
        for channel in 0..<channelCount {
            let clamped = min(max(currentPeaks[channel], 0), 1)
            channels[channel].append(UInt8((clamped * 255).rounded()))
            currentPeaks[channel] = 0
        }
        framesInBucket = 0
    }
}

/// A stable, non-cryptographic 64-bit hash (FNV-1a) for cache file names.
public enum StableHash {
    public static func hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }
}
