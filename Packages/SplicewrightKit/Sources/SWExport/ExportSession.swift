import AVFoundation
import Combine
import SWCore
import SWMedia
import SWPlayback
import VideoToolbox

public enum ExportState: Equatable, Sendable {
    case idle
    case preparing
    case exporting
    case finished(URL)
    case failed(String)
    case cancelled

    public var isRunning: Bool { self == .preparing || self == .exporting }
}

/// Exports a snapshot of a sequence to a file. Frames come from the same composition and
/// Metal compositor as playback, so the file matches the Program monitor.
@MainActor
public final class ExportSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let settings: ExportSettings
    public let outputURL: URL
    public let sequenceName: String

    @Published public private(set) var state: ExportState = .idle
    /// 0...1
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var startedAt: Date?

    private let sequence: EditSequence
    private let project: Project
    private var worker: ExportWorker?
    private var cancelRequested = false

    /// `sequence` and `project` are copied, so editing can continue during the export.
    public init(sequence: EditSequence, project: Project, settings: ExportSettings, outputURL: URL) {
        self.sequence = sequence
        self.project = project
        self.settings = settings
        self.outputURL = outputURL
        sequenceName = sequence.name
    }

    /// Seconds left, extrapolated from progress so far.
    public var estimatedSecondsRemaining: Double? {
        guard let startedAt, progress > 0.02, state == .exporting else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        return max(0, elapsed / progress - elapsed)
    }

    public func start() {
        guard state == .idle else { return }
        if let error = settings.validate(for: sequence).first {
            state = .failed(error.message)
            return
        }
        state = .preparing
        startedAt = Date()
        Task { await run() }
    }

    /// Runs the export to completion; returns the final state. Used by tests and the smoke test.
    @discardableResult
    public func run() async -> ExportState {
        if state == .idle {
            state = .preparing
            startedAt = Date()
        }
        do {
            let worker = try await makeWorker()
            self.worker = worker
            if cancelRequested { worker.cancel() }
            state = .exporting
            try await worker.run { [weak self] fraction in
                Task { @MainActor in self?.progress = max(self?.progress ?? 0, min(fraction, 1)) }
            }
            progress = 1
            state = .finished(outputURL)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            state = .cancelled
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            state = .failed(Self.describe(error))
        }
        worker = nil
        return state
    }

    public func cancel() {
        cancelRequested = true
        worker?.cancel()
    }

    private func makeWorker() async throws -> ExportWorker {
        guard let frames = settings.frameRange(for: sequence), !frames.isEmpty else {
            throw ExportError.message(ExportValidationError.emptyRange.message)
        }
        let (width, height) = settings.outputSize(for: sequence)
        let outputRate = settings.outputRate(for: sequence)
        let builder = CompositionBuilder(renderSize: CGSize(width: width, height: height),
                                         outputColorSpace: settings.preset.colorSpace, frameRate: outputRate)
        let output = await builder.build(sequence, project: project, cache: MediaAssetCache())
        let rate = sequence.rate
        let range = CMTimeRange(start: RationalTime(frames: frames.start, rate: rate).cmTime,
                                end: RationalTime(frames: frames.end, rate: rate).cmTime)
        try? FileManager.default.removeItem(at: outputURL)
        return try await ExportWorker(output: output, settings: settings, chapters: settings.chapters(for: sequence),
                                      range: range, width: width, height: height,
                                      fps: outputRate.framesPerSecond, url: outputURL)
    }

    static func describe(_ error: Error) -> String {
        if case ExportError.message(let text) = error { return text }
        let nsError = error as NSError
        var text = nsError.localizedDescription
        if let reason = nsError.localizedFailureReason { text += " \(reason)" }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code))"
        }
        return text
    }
}

enum ExportError: Error {
    case message(String)
}

/// The AVAssetReader → AVAssetWriter pipeline for one export.
final class ExportWorker: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderAudioMixOutput?
    private let audioInput: AVAssetWriterInput?
    /// Chapter marks: a text track the video track points to as its chapter list.
    private let chapterTrack: ChapterTrack?
    private let range: CMTimeRange
    private let lock = NSLock()
    private var cancelled = false

    init(output: CompositionOutput, settings: ExportSettings, chapters: [Chapters.Chapter] = [], range: CMTimeRange,
         width: Int, height: Int, fps: Double, url: URL) async throws {
        self.range = range
        let preset = settings.preset
        let colorProperties = ExportColor.properties(for: preset.colorSpace)

        reader = try AVAssetReader(asset: output.composition)
        reader.timeRange = range
        let videoTracks = try await output.composition.loadTracks(withMediaType: .video)
        let pixelFormat = preset.codec.bitDepth >= 10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                      : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat),
            AVVideoColorPropertiesKey: colorProperties,
        ])
        videoOutput.videoComposition = output.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.message("Couldn't read the sequence's video.") }
        reader.add(videoOutput)

        let audioTracks = try await output.composition.loadTracks(withMediaType: .audio)
            .filter { track in track.segments.contains { !$0.isEmpty } }
        if audioTracks.isEmpty {
            audioOutput = nil
        } else {
            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: ExportAudio.readerSettings)
            mixOutput.audioMix = output.audioMix
            mixOutput.audioTimePitchAlgorithm = output.audioTimePitchAlgorithm
            mixOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(mixOutput) else { throw ExportError.message("Couldn't read the sequence's audio.") }
            reader.add(mixOutput)
            audioOutput = mixOutput
        }

        writer = try AVAssetWriter(outputURL: url, fileType: preset.container == .mp4 ? .mp4 : .mov)
        let format = VideoFormat(preset: preset, width: width, height: height, fps: fps,
                                 bitRate: settings.bitRate(width: width, height: height, fps: fps),
                                 colorProperties: colorProperties)
        videoInput = try Self.makeVideoInput(writer: writer, format: format)
        writer.add(videoInput)

        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: ExportAudio.writerSettings(preset.audio))
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.message("This file type can't hold the chosen audio.") }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
        chapterTrack = ChapterTrack(chapters, range: range, writer: writer, video: videoInput)
    }

    struct VideoFormat {
        var preset: ExportPreset
        var width: Int
        var height: Int
        var fps: Double
        var bitRate: Int?
        var colorProperties: [String: String]
    }

    private static func makeVideoInput(writer: AVAssetWriter, format: VideoFormat) throws -> AVAssetWriterInput {
        let (preset, width, height, fps) = (format.preset, format.width, format.height, format.fps)
        var compression: [String: Any] = [:]
        if let bitRate = format.bitRate {
            compression[AVVideoAverageBitRateKey] = bitRate
            compression[AVVideoExpectedSourceFrameRateKey] = fps
            compression[AVVideoMaxKeyFrameIntervalKey] = max(1, Int(fps.rounded()))
            compression[AVVideoAllowFrameReorderingKey] = true
        }
        switch preset.codec {
        case .h264: compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc: compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        case .hevc10: compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy: break
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: ExportColor.codecType(preset.codec),
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: format.colorProperties,
        ]
        if !compression.isEmpty { settings[AVVideoCompressionPropertiesKey] = compression }

        // Ask the encoder to write HDR metadata (mastering display / content light level) when it can.
        if preset.colorSpace.isHDR, preset.codec == .hevc10 {
            var hdrCompression = compression
            hdrCompression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] =
                kVTHDRMetadataInsertionMode_Auto as String
            var hdrSettings = settings
            hdrSettings[AVVideoCompressionPropertiesKey] = hdrCompression
            if writer.canApply(outputSettings: hdrSettings, forMediaType: .video) { settings = hdrSettings }
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw ExportError.message("This Mac can't encode \(preset.codec.displayName) at \(width)×\(height) " +
                                      "into a .\(preset.container.fileExtension) file.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ExportError.message("Couldn't add the video track to the file.") }
        return input
    }

    /// Stops the export. Cancelling the reader wakes a pump blocked waiting for a rendered frame;
    /// a pump whose writer input never becomes ready again is released shortly after.
    func cancel() {
        lock.lock()
        cancelled = true
        let pending = pumps
        lock.unlock()
        if reader.status == .reading { reader.cancelReading() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            pending.forEach { $0.finish() }
        }
    }

    private var pumps: [PumpCompletion] = []

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isCancelled { throw CancellationError() }
        guard writer.startWriting() else { throw writer.error ?? ExportError.message("Couldn't create the file.") }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? ExportError.message("Couldn't start rendering the sequence.")
        }
        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        writer.startSession(atSourceTime: range.start)
        let duration = max(range.duration.seconds, 1e-6)
        let start = range.start

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                await pump(videoOutput, into: videoInput, queue: "video") { time in
                    progress((time - start).seconds / duration)
                }
            }
            if let audioOutput, let audioInput {
                group.addTask { [self] in await pump(audioOutput, into: audioInput, queue: "audio", onSample: nil) }
            }
            if let chapterTrack {
                group.addTask { [self] in await pumpChapters(chapterTrack) }
            }
        }

        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? ExportError.message("Rendering failed.")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ExportError.message("Writing the file failed.")
        }
    }

    /// Writes the chapter samples when the writer wants them (it interleaves them with the video).
    private func pumpChapters(_ track: ChapterTrack) async {
        let input = track.input
        let queue = DispatchQueue(label: "com.splicewright.export.chapters")
        let completion = PumpCompletion()
        lock.lock()
        pumps.append(completion)
        lock.unlock()
        let next = ChapterCursor()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completion.wait(continuation)
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while !completion.isFinished && input.isReadyForMoreMediaData {
                    guard !isCancelled, next.index < track.samples.count, input.append(track.samples[next.index]) else {
                        input.markAsFinished()
                        completion.finish()
                        return
                    }
                    next.index += 1
                }
            }
        }
    }

    /// Feeds one reader output into one writer input until either runs out or fails.
    private func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, queue label: String,
                      onSample: ((CMTime) -> Void)?) async {
        let queue = DispatchQueue(label: "com.splicewright.export.\(label)")
        let completion = PumpCompletion()
        lock.lock()
        pumps.append(completion)
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { completion.finish() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completion.wait(continuation)
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while !completion.isFinished && input.isReadyForMoreMediaData {
                    guard !isCancelled, reader.status == .reading, let sample = output.copyNextSampleBuffer(),
                          input.append(sample) else {
                        input.markAsFinished()
                        completion.finish()
                        return
                    }
                    onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
                }
            }
        }
    }
}

/// Resumes a pump's continuation exactly once, from the pump or from `cancel()`.
private final class PumpCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func wait(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

enum ExportColor {
    static func properties(for space: SequenceColorSpace) -> [String: String] {
        switch space {
        case .rec709:
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        case .rec2100HLG:
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        case .rec2100PQ:
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
    }

    static func codecType(_ codec: ExportCodec) -> AVVideoCodecType {
        switch codec {
        case .h264: return .h264
        case .hevc, .hevc10: return .hevc
        case .proRes422HQ: return .proRes422HQ
        case .proRes422: return .proRes422
        case .proRes422LT: return .proRes422LT
        case .proRes422Proxy: return .proRes422Proxy
        }
    }
}

enum ExportAudio {
    static let readerSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    static func writerSettings(_ codec: ExportAudioCodec) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        switch codec {
        case .aac:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 320_000, AVChannelLayoutKey: layoutData]
        case .pcm24:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false, AVChannelLayoutKey: layoutData]
        }
    }
}

/// The next chapter to write; touched only on the chapter input's queue.
private final class ChapterCursor: @unchecked Sendable {
    var index = 0
}
