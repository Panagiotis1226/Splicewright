import AVFoundation
import CoreVideo
import SWCore
import VideoToolbox

public enum ProxyError: Error, Equatable, LocalizedError {
    case noVideo
    case cannotRead(String)
    case cannotWrite(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideo: return "This file has no video to make a proxy of."
        case .cannotRead(let reason): return "Couldn't read the video: \(reason)"
        case .cannotWrite(let reason): return "Couldn't write the proxy: \(reason)"
        case .cancelled: return "Cancelled."
        }
    }
}

/// Writes a ProRes proxy of a clip's video: decoded at the source's bit depth, scaled with
/// VideoToolbox, tagged with the source's colors and rotation, and timed frame for frame.
/// Audio is not copied; playback always takes audio from the original.
public final class ProxyGenerator: @unchecked Sendable {
    private let store: ProxyStore
    private let lock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?

    public init(store: ProxyStore = .shared) {
        self.store = store
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let reader = self.reader
        lock.unlock()
        if reader?.status == .reading { reader?.cancelReading() }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Creates the proxy and registers it with the store. `progress` is called with 0...1.
    @discardableResult
    public func makeProxy(for item: MediaItem, preset: ProxyPreset,
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let asset = AVURLAsset(url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProxyError.noVideo }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let duration = try await asset.load(.duration)
        let (width, height) = preset.size(width: Int(abs(natural.width).rounded()), height: Int(abs(natural.height).rounded()))
        let tenBit = (item.info.video?.bitDepth ?? 8) > 8

        let destination = store.url(for: item, preset: preset)
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).mov")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw ProxyError.cannotRead(error.localizedDescription) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: tenBit
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ProxyError.cannotRead("unsupported track") }
        reader.add(output)

        let (writer, adaptor) = try Self.makeWriter(at: temporary, item: item, preset: preset,
                                                    size: (width, height), transform: transform)

        var transfer: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr,
              let transfer else { throw ProxyError.cannotWrite("couldn't create a scaler") }
        defer { VTPixelTransferSessionInvalidate(transfer) }

        lock.lock()
        self.reader = reader
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw ProxyError.cancelled }
        guard writer.startWriting() else {
            throw ProxyError.cannotWrite(writer.error?.localizedDescription ?? "unknown error")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw ProxyError.cannotRead(reader.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        let job = Pump(output: output, adaptor: adaptor, transfer: transfer, duration: duration.seconds,
                       isCancelled: { [weak self] in self?.isCancelled ?? true }, progress: progress)
        let failure = await job.run(queue: DispatchQueue(label: "com.splicewright.proxy"))

        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw ProxyError.cancelled
        }
        if reader.status == .failed || failure != nil {
            writer.cancelWriting()
            throw ProxyError.cannotRead(reader.error?.localizedDescription ?? failure ?? "unknown error")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ProxyError.cannotWrite(writer.error?.localizedDescription ?? "unknown error")
        }
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.moveItem(at: temporary, to: destination) } catch {
            throw ProxyError.cannotWrite(error.localizedDescription)
        }
        store.register(destination, for: item, preset: preset, width: width, height: height)
        progress(1)
        return destination
    }
}

extension ProxyGenerator {
    static func makeWriter(at url: URL, item: MediaItem, preset: ProxyPreset, size: (width: Int, height: Int),
                           transform: CGAffineTransform) throws -> (AVAssetWriter, AVAssetWriterInputPixelBufferAdaptor) {
        let (width, height) = size
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) } catch {
            throw ProxyError.cannotWrite(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: preset.codec == .proRes422Proxy ? AVVideoCodecType.proRes422Proxy : AVVideoCodecType.proRes422LT,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: ColorTags.writerProperties(item.info.video?.color ?? .rec709),
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw ProxyError.cannotWrite("this Mac can't encode \(preset.codec.displayName)")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { throw ProxyError.cannotWrite("couldn't add the video track") }
        writer.add(input)
        return (writer, adaptor)
    }
}

/// Moves frames from the reader to the writer, scaling each one.
private final class Pump: @unchecked Sendable {
    let output: AVAssetReaderTrackOutput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let transfer: VTPixelTransferSession
    let duration: Double
    let isCancelled: () -> Bool
    let progress: (Double) -> Void
    private var finished = false

    init(output: AVAssetReaderTrackOutput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
         transfer: VTPixelTransferSession, duration: Double, isCancelled: @escaping () -> Bool,
         progress: @escaping (Double) -> Void) {
        self.output = output
        self.adaptor = adaptor
        self.transfer = transfer
        self.duration = duration
        self.isCancelled = isCancelled
        self.progress = progress
    }

    /// Returns nil on success, or a reason the pump stopped early.
    func run(queue: DispatchQueue) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let input = adaptor.assetWriterInput
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while !finished && input.isReadyForMoreMediaData {
                    var failure: String?
                    if isCancelled() {
                        failure = "cancelled"
                    } else if let sample = output.copyNextSampleBuffer() {
                        if let reason = append(sample) { failure = reason } else { continue }
                    }
                    // End of media, cancellation or a failure.
                    finished = true
                    input.markAsFinished()
                    continuation.resume(returning: failure)
                    return
                }
            }
        }
    }

    private func append(_ sample: CMSampleBuffer) -> String? {
        guard let source = CMSampleBufferGetImageBuffer(sample) else { return nil }  // e.g. an empty marker sample
        guard let pool = adaptor.pixelBufferPool else { return "no pixel buffer pool" }
        var scaled: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled) == kCVReturnSuccess, let scaled else {
            return "out of memory"
        }
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled) == noErr else {
            return "couldn't scale a frame"
        }
        CVBufferPropagateAttachments(source, scaled)
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard adaptor.append(scaled, withPresentationTime: time) else { return "couldn't encode a frame" }
        if duration > 0 { progress(min(time.seconds / duration, 0.999)) }
        return nil
    }
}
