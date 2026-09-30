import AVFoundation
import CoreMedia
import SWCore

public enum WaveformError: Error {
    case noAudio
    case readerFailed(Error?)
}

/// Reads a file's first audio track as Float32 PCM and reduces it to `WaveformPeaks`.
public actor WaveformProvider {
    public static let shared = WaveformProvider()

    private var memory: [String: WaveformPeaks] = [:]
    private var inFlight: [String: Task<WaveformPeaks?, Never>] = [:]
    private let directory: URL

    public init(directory: URL = MediaCache.directory("Waveforms")) {
        self.directory = directory
    }

    public func peaks(for url: URL) async -> WaveformPeaks? {
        let key = MediaCache.fingerprint(of: url, extra: "peaks-v1")
        if let cached = memory[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let fileURL = directory.appending(path: "\(key).json")
        let task = Task.detached(priority: .utility) { () -> WaveformPeaks? in
            if let data = try? Data(contentsOf: fileURL),
               let peaks = try? JSONDecoder().decode(WaveformPeaks.self, from: data) {
                return peaks
            }
            guard let peaks = try? await Self.generate(url: url) else { return nil }
            if let data = try? JSONEncoder().encode(peaks) { try? data.write(to: fileURL, options: .atomic) }
            return peaks
        }
        inFlight[key] = task
        let peaks = await task.value
        inFlight[key] = nil
        if let peaks { memory[key] = peaks }
        return peaks
    }

    public static func generate(url: URL) async throws -> WaveformPeaks {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw WaveformError.noAudio }
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let description = formatDescriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mChannelsPerFrame > 0 else {
            throw WaveformError.noAudio
        }
        let channelCount = Int(asbd.mChannelsPerFrame)
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WaveformError.readerFailed(nil) }
        reader.add(output)
        guard reader.startReading() else { throw WaveformError.readerFailed(reader.error) }

        var accumulator = PeakAccumulator(channelCount: channelCount, sampleRate: sampleRate)
        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if samples.count != count { samples = [Float](repeating: 0, count: count) }
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                                  destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            accumulator.append(interleaved: samples)
        }
        if reader.status == .failed { throw WaveformError.readerFailed(reader.error) }
        return accumulator.finish()
    }
}
