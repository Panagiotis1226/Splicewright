import AppKit
import AVFoundation
import SWCore

/// Records the default microphone into a CAF file (32-bit float, the input's own rate and channels).
final class VoiceoverRecorder: @unchecked Sendable {
    enum Failure: Error { case noInput }

    let url: URL
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var peak: Float = 0

    init(url: URL) { self.url = url }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        self.file = file
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? file.write(from: buffer)
            var loudest: Float = 0
            if let data = buffer.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) { loudest = max(loudest, abs(data[channel][frame])) }
                }
            }
            self.lock.lock()
            self.peak = max(self.peak, loudest)
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
    }

    /// The loudest sample since the last call (0...1), for the level meter.
    func takePeak() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}

/// A voiceover being recorded: a count-in, then recording onto `trackID` from `startFrame`.
@MainActor
public final class VoiceoverSession: ObservableObject {
    public enum Phase: Equatable {
        case countIn(Int)
        case recording
        case finishing
    }

    @Published public internal(set) var phase: Phase = .countIn(3)
    @Published public internal(set) var level: Float = 0
    @Published public internal(set) var seconds: Double = 0
    public let trackID: UUID
    public let startFrame: Int64
    var recorder: VoiceoverRecorder?
    var wasMuted = false
    var isCancelled = false

    init(trackID: UUID, startFrame: Int64) {
        self.trackID = trackID
        self.startFrame = startFrame
    }
}

extension WorkspaceController {
    /// Where takes are kept.
    static var voiceoverFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appending(path: "Splicewright/Voiceovers", directoryHint: .isDirectory)
    }

    /// Clip ▸ Record Voiceover (and the Timeline's mic button): starts, or stops and places the take.
    public func toggleVoiceover() {
        if voiceover == nil { startVoiceover() } else { stopVoiceover() }
    }

    /// A three-second count-in, then records the microphone onto the targeted audio track (or
    /// `trackID`) from the playhead while the sequence plays (muted, so speakers don't feed back).
    public func startVoiceover(on trackID: UUID? = nil) {
        guard voiceover == nil, let sequence = activeSequence else { return }
        guard let track = trackID ?? sequence.targetedAudioTrackID
                ?? sequence.audioTracks.first(where: { !$0.isLocked })?.id else {
            voiceoverMessage = "Unlock an audio track to record onto."
            return
        }
        let session = VoiceoverSession(trackID: track, startFrame: playheadFrame)
        voiceover = session
        voiceoverMessage = nil
        Task { @MainActor in
            guard await microphoneAllowed() else {
                voiceover = nil
                voiceoverMessage = "Splicewright can't use the microphone. Allow it in System Settings ▸ Privacy & "
                    + "Security ▸ Microphone, then try again."
                return
            }
            for count in stride(from: 3, through: 1, by: -1) {
                guard !session.isCancelled else { return }
                session.phase = .countIn(count)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !session.isCancelled else { return }
            beginRecording(session)
        }
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func beginRecording(_ session: VoiceoverSession) {
        let folder = Self.voiceoverFolder
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = folder.appending(path: "Voiceover \(formatter.string(from: Date())).caf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let recorder = VoiceoverRecorder(url: url)
            try recorder.start()
            session.recorder = recorder
        } catch {
            AppLog.shared.warning("Voiceover couldn't start: \(error.localizedDescription)", category: "voiceover")
            voiceover = nil
            voiceoverMessage = "Couldn't record from the microphone (\(error.localizedDescription))."
            return
        }
        session.phase = .recording
        session.wasMuted = program.player.isMuted
        program.player.isMuted = true
        program.seek(toFrame: session.startFrame)
        if !program.isPlaying { program.togglePlay() }
        let started = Date()
        Task { @MainActor in
            while session.phase == .recording, let recorder = session.recorder {
                session.level = recorder.takePeak()
                session.seconds = Date().timeIntervalSince(started)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Stops recording, imports the take and places it on the track where recording started.
    public func stopVoiceover() {
        guard let session = voiceover else { return }
        guard session.phase == .recording, let recorder = session.recorder else {
            // Still counting in: nothing recorded yet.
            session.isCancelled = true
            voiceover = nil
            return
        }
        session.phase = .finishing
        recorder.stop()
        if program.isPlaying { program.pause() }
        program.player.isMuted = session.wasMuted
        let url = recorder.url
        Task { @MainActor in
            defer { voiceover = nil }
            importFiles([url])
            for _ in 0..<300 where isImporting { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard let item = project.media.first(where: { $0.filePath == url.path }) else {
                voiceoverMessage = "The take was saved to \(url.path) but couldn't be imported."
                return
            }
            dropMedia([item.id], atFrame: session.startFrame, trackID: session.trackID, insert: false)
            AppLog.shared.info("Recorded voiceover \(url.lastPathComponent)", category: "voiceover")
        }
    }
}
