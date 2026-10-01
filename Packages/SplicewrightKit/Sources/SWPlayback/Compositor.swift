import AVFoundation
import CoreVideo
import SWCore

/// One layer in a composition instruction.
struct InstructionLayer {
    var trackID: CMPersistentTrackID
    var opacity: Double
    /// Encoded source pixels → render pixels (orientation and fit included).
    var transform: Affine2D
    var sourceWidth: Double
    var sourceHeight: Double
    var fallbackColor: ColorDescription
    /// Interpret Footage override: used instead of the frame's own tags.
    var forcedColor: ColorDescription?
    /// Set when this layer is one side of a transition.
    var transition: InstructionTransition?
    /// Set for a title layer, which has no source track (`trackID` is invalid).
    var title: TitleSpec?
    /// Keyframeable motion and opacity, applied after `transform`.
    var motion = Motion()
    /// Composition time of the clip's first frame, and the source time shown there.
    var clipStart: CMTime = .zero
    var sourceStart: RationalTime = .zero
    /// Sequence pixels → render pixels (below 1 at reduced playback resolution).
    var pixelScale: Double = 1

    /// The source time shown at a composition time, for evaluating keyframes.
    func sourceTime(at time: CMTime) -> RationalTime {
        sourceStart + RationalTime(seconds: (time - clipStart).seconds, timescale: 600_000)
    }

    /// Fit, then motion, at a composition time.
    func transform(at time: CMTime, renderWidth: Double, renderHeight: Double) -> Affine2D {
        guard !motion.isIdentity else { return transform }
        return transform.concatenating(motion.transform(at: sourceTime(at: time), renderWidth: renderWidth,
                                                        renderHeight: renderHeight, scale: pixelScale))
    }

    func opacity(at time: CMTime) -> Double {
        motion.opacity(at: sourceTime(at: time))
    }
}

/// A layer's part in a transition, in composition time.
struct InstructionTransition {
    var id: UUID
    var kind: TransitionKind
    var start: CMTime
    var duration: CMTime
    var frameDuration: CMTime
    var role: LayerTransition.Role

    init(_ transition: LayerTransition, rate: FrameRate) {
        id = transition.id
        kind = transition.kind
        start = RationalTime(frames: transition.range.start, rate: rate).cmTime
        duration = RationalTime(frames: transition.range.length, rate: rate).cmTime
        frameDuration = rate.cmFrameDuration
        role = transition.role
    }

    /// 0 at the transition's first frame, approaching 1 at its last. Frames are sampled at
    /// their centers so a dissolve is symmetrical.
    func progress(at time: CMTime) -> Double {
        let elapsed = (time - start).seconds + frameDuration.seconds / 2
        return min(max(elapsed / max(duration.seconds, 1e-9), 0), 1)
    }
}

/// Program-monitor diagnostics drawn by the compositor's output pass.
public enum OverlayMode: Sendable, Hashable {
    case none
    /// Magenta where the output clips (above SDR white or 1000 nits), blue below black or out of gamut.
    case clipping
}

/// Describes what to draw for one stretch of the timeline.
final class CompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// Transitions change every frame.
    let containsTweening: Bool
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let layers: [InstructionLayer]
    let outputSpace: SequenceColorSpace
    let overlay: OverlayMode

    /// `everyFrame` asks AVFoundation for every output frame even when nothing changes;
    /// without it, an export faster than the sequence would only get the source's frames.
    init(timeRange: CMTimeRange, layers: [InstructionLayer], outputSpace: SequenceColorSpace,
         overlay: OverlayMode = .none, everyFrame: Bool = false) {
        self.timeRange = timeRange
        self.layers = layers
        self.outputSpace = outputSpace
        self.overlay = overlay
        containsTweening = everyFrame || layers.contains { $0.transition != nil || $0.motion.isAnimated }
        let ids = Array(Set(layers.map(\.trackID).filter { $0 != kCMPersistentTrackID_Invalid })).sorted()
        requiredSourceTrackIDs = ids.isEmpty ? nil : ids.map { NSNumber(value: $0) }
    }
}

/// Splicewright's video compositor: draws every visible layer with Metal in a linear
/// Rec.2020 working space and encodes the result for the sequence's color space.
/// AVFoundation uses the same compositor for playback, thumbnails and export.
final class SplicewrightCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(label: "com.splicewright.compositor", qos: .userInteractive)
    private var cancelGeneration = 0
    private let stateLock = NSLock()

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: PlanarFormat.accepted.map { NSNumber(value: $0) },
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_64RGBAHalf),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    var supportsWideColorSourceFrames: Bool { true }
    var supportsHDRSourceFrames: Bool { true }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let generation = currentGeneration()
        renderQueue.async { [weak self] in
            guard let self else { return }
            guard generation == self.currentGeneration() else {
                request.finishCancelledRequest()
                return
            }
            do {
                request.finish(withComposedVideoFrame: try self.render(request))
            } catch {
                request.finish(with: error)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        stateLock.lock()
        cancelGeneration += 1
        stateLock.unlock()
    }

    private func currentGeneration() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelGeneration
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let output = request.renderContext.newPixelBuffer() else { throw RenderError.textureCreationFailed }
        guard let renderer = MetalRenderer.shared else { throw RenderError.noMetalDevice }
        guard let instruction = request.videoCompositionInstruction as? CompositionInstruction else {
            try renderer.render(layers: [], into: output, space: .rec709)
            return output
        }
        let time = request.compositionTime
        let renderSize = request.renderContext.size
        func frame(_ layer: InstructionLayer) -> LayerSource? {
            let transform = layer.transform(at: time, renderWidth: renderSize.width, renderHeight: renderSize.height)
            let opacity = layer.opacity(at: time)
            if let title = layer.title {
                return .title(TitleFrame(spec: title, opacity: opacity, transform: transform))
            }
            guard let buffer = request.sourceFrame(byTrackID: layer.trackID) else { return nil }
            return .video(LayerFrame(pixelBuffer: buffer, transform: transform, sourceWidth: layer.sourceWidth,
                                     sourceHeight: layer.sourceHeight, opacity: opacity,
                                     fallbackColor: layer.fallbackColor, forcedColor: layer.forcedColor))
        }
        var items: [RenderItem] = []
        var index = instruction.layers.startIndex
        while index < instruction.layers.endIndex {
            let layer = instruction.layers[index]
            guard let transition = layer.transition else {
                if let frame = frame(layer) { items.append(.layer(frame)) }
                index += 1
                continue
            }
            // A transition's outgoing and incoming layers are adjacent.
            var mix = TransitionFrame(outgoing: nil, incoming: nil, kind: transition.kind,
                                      progress: transition.progress(at: request.compositionTime))
            while index < instruction.layers.endIndex, let side = instruction.layers[index].transition,
                  side.id == transition.id {
                switch side.role {
                case .outgoing: mix.outgoing = frame(instruction.layers[index])
                case .incoming: mix.incoming = frame(instruction.layers[index])
                }
                index += 1
            }
            items.append(.transition(mix))
        }
        try renderer.render(items: items, into: output, space: instruction.outputSpace, overlay: instruction.overlay)
        return output
    }
}
