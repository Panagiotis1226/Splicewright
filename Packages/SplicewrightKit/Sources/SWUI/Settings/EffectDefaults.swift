import Combine
import Foundation
import SWCore

/// The default video and audio transitions (applied by ⌘D / ⇧⌘D), saved in preferences.
@MainActor
public final class EffectDefaults: ObservableObject {
    public static let shared = EffectDefaults()

    @Published public var videoTransition: TransitionKind {
        didSet { defaults.set(videoTransition.rawValue, forKey: "defaultVideoTransition") }
    }

    @Published public var audioTransition: TransitionKind {
        didSet { defaults.set(audioTransition.rawValue, forKey: "defaultAudioTransition") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let video = defaults.string(forKey: "defaultVideoTransition").flatMap(TransitionKind.init(rawValue:))
        let audio = defaults.string(forKey: "defaultAudioTransition").flatMap(TransitionKind.init(rawValue:))
        videoTransition = video.flatMap { $0.isAudio ? nil : $0 } ?? .crossDissolve
        audioTransition = audio.flatMap { $0.isAudio ? $0 : nil } ?? .constantPower
    }

    public func isDefault(_ kind: TransitionKind) -> Bool {
        kind == (kind.isAudio ? audioTransition : videoTransition)
    }

    public func makeDefault(_ kind: TransitionKind) {
        if kind.isAudio { audioTransition = kind } else { videoTransition = kind }
    }
}
