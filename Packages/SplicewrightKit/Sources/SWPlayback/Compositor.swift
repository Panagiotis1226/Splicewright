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

    init(timeRange: CMTimeRange, layers: [InstructionLayer], outputSpace: SequenceColorSpace,
         overlay: OverlayMode = .none) {
        self.timeRange = timeRange
        self.layers = layers
        self.outputSpace = outputSpace
        self.overlay = overlay
        containsTweening = layers.contains { $0.transition != nil }
        let ids = Array(Set(layers.map(\.trackID))).sorted()
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
        func frame(_ layer: InstructionLayer) -> LayerFrame? {
            guard let buffer = request.sourceFrame(byTrackID: layer.trackID) else { return nil }
            return LayerFrame(pixelBuffer: buffer, transform: layer.transform, sourceWidth: layer.sourceWidth,
                              sourceHeight: layer.sourceHeight, opacity: layer.opacity,
                              fallbackColor: layer.fallbackColor, forcedColor: layer.forcedColor)
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
