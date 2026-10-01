import AVFoundation
import Speech
import SWCore

/// Speech to text with macOS's on-device recognition: nothing is uploaded and no model ships
/// with the app. macOS 26 uses SpeechAnalyzer (long-form, more accurate); macOS 15 uses
/// SFSpeechRecognizer in on-device mode, in 50-second pieces.
public enum Transcriber {
    public enum Failure: Error, LocalizedError, Equatable {
        case notAuthorized
        case unsupportedLanguage(String)
        case unavailable(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Splicewright isn't allowed to use speech recognition. Turn it on in System Settings ▸ "
                    + "Privacy & Security ▸ Speech Recognition."
            case .unsupportedLanguage(let name): return "On-device transcription isn't available for \(name)."
            case .unavailable(let reason): return "Speech recognition isn't available: \(reason)"
            case .failed(let reason): return "Transcription failed: \(reason)"
            }
        }
    }

    /// What's happening, for the progress sheet.
    public enum Stage: Sendable, Equatable {
        case mixingAudio
        case downloadingLanguage(Double)
        case transcribing(Double)
    }

    /// Whether the newer engine is in use.
    public static var usesSpeechAnalyzer: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Languages that can be transcribed on this Mac.
    public static func supportedLocales() async -> [Locale] {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            return await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
        }
        #endif
        return SFSpeechRecognizer.supportedLocales()
            .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            .sorted { $0.identifier < $1.identifier }
    }

    /// Asks for speech recognition permission (once; macOS remembers the answer).
    public static func requestAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        guard status == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// Words in `file` (16 kHz mono works best), with times in seconds from its start.
    /// `requestPermission` is off in tests: asking from a process without a usage
    /// description would end it.
    public static func words(in file: URL, locale: Locale, requestPermission: Bool = true,
                             stage: @escaping @Sendable (Stage) -> Void = { _ in }) async throws -> [TimedWord] {
        let allowed = requestPermission ? await requestAuthorization()
            : SFSpeechRecognizer.authorizationStatus() == .authorized
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            return try await ModernEngine.words(in: file, locale: locale, stage: stage)
        }
        #endif
        guard allowed else { throw Failure.notAuthorized }
        return try await LegacyEngine.words(in: file, locale: locale, stage: stage)
    }
}

#if compiler(>=6.2)
/// macOS 26: SpeechAnalyzer with a SpeechTranscriber module, timing every word.
@available(macOS 26, *)
private enum ModernEngine {
    static func words(in file: URL, locale: Locale,
                      stage: @escaping @Sendable (Transcriber.Stage) -> Void) async throws -> [TimedWord] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Transcriber.Failure.unsupportedLanguage(locale.localizedString(forIdentifier: locale.identifier)
                                                          ?? locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // The language model downloads once, then stays on the Mac.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progress = request.progress
            let watcher = Task {
                while !Task.isCancelled {
                    stage(.downloadingLanguage(progress.fractionCompleted))
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
        }

        let audio = try AVAudioFile(forReading: file)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [TimedWord] in
            var words: [TimedWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    words.append(TimedWord(text: text, start: range.start.seconds, duration: range.duration.seconds))
                    if duration > 0 { stage(.transcribing(min(range.end.seconds / duration, 0.99))) }
                }
            }
            return words
        }
        do {
            stage(.transcribing(0))
            if let last = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw Transcriber.Failure.failed(error.localizedDescription)
        }
        return Self.merged(try await collector.value)
    }

    /// Runs can split a word from its trailing punctuation; join tokens that start with it.
    static func merged(_ words: [TimedWord]) -> [TimedWord] {
        var result: [TimedWord] = []
        for word in words {
            if let first = word.text.first, ",.!?;:…%)”’".contains(first), var last = result.popLast() {
                last.text += word.text
                last.duration = max(last.duration, word.end - last.start)
                result.append(last)
            } else {
                result.append(word)
            }
        }
        return result
    }
}
#endif

/// macOS 15: SFSpeechRecognizer on-device, fed overlapping 50-second pieces.
private enum LegacyEngine {
    static let piece = 50.0
    static let overlap = 1.0

    static func words(in file: URL, locale: Locale,
                      stage: @escaping @Sendable (Transcriber.Stage) -> Void) async throws -> [TimedWord] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw Transcriber.Failure.unsupportedLanguage(locale.localizedString(forIdentifier: locale.identifier)
                                                          ?? locale.identifier)
        }
        guard recognizer.isAvailable else { throw Transcriber.Failure.unavailable("the recognizer is busy") }
        let audio = try AVAudioFile(forReading: file)
        let sampleRate = audio.processingFormat.sampleRate
        let duration = Double(audio.length) / sampleRate
        var words: [TimedWord] = []
        var start = 0.0
        while start < duration {
            try Task.checkCancellation()
            stage(.transcribing(start / max(duration, 1)))
            let length = min(piece + overlap, duration - start)
            let chunk = try extract(audio, from: start, length: length)
            defer { try? FileManager.default.removeItem(at: chunk) }
            let pieceWords = try await recognize(chunk, with: recognizer).map {
                TimedWord(text: $0.text, start: $0.start + start, duration: $0.duration)
            }
            // Words in the overlap belong to whichever piece has more context: split at its middle.
            let lower = start == 0 ? -Double.infinity : start + overlap / 2
            let upper = start + piece + overlap / 2
            words += pieceWords.filter { $0.start >= lower && $0.start < upper }
            start += piece
        }
        return words
    }

    private static func extract(_ audio: AVAudioFile, from start: Double, length: Double) throws -> URL {
        let format = audio.processingFormat
        let frames = AVAudioFrameCount(length * format.sampleRate)
        audio.framePosition = AVAudioFramePosition(start * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw Transcriber.Failure.failed("out of memory")
        }
        try audio.read(into: buffer, frameCount: frames)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("splicewright-piece-\(UUID().uuidString).caf")
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        try output.write(from: buffer)
        return url
    }

    private static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> [TimedWord] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        TimedWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    })
                } else if let error {
                    finished = true
                    // "No speech detected" is an empty piece, not a failure.
                    let code = (error as NSError).code
                    if code == 1110 || code == 203 {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: Transcriber.Failure.failed(error.localizedDescription))
                    }
                }
            }
        }
    }
}
