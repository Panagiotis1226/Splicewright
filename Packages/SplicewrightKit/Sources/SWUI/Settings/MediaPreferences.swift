import Combine
import Foundation
import SWCore
import SWMedia

/// Proxy settings, saved in preferences.
@MainActor
public final class MediaPreferences: ObservableObject {
    public static let shared = MediaPreferences()

    @Published public var proxyPreset: ProxyPreset {
        didSet { save(proxyPreset, "proxyPreset") }
    }

    /// Create proxies on import for video larger than the proxy preset.
    @Published public var autoCreateProxies: Bool {
        didSet { defaults.set(autoCreateProxies, forKey: "autoCreateProxies") }
    }

    /// nil uses the default location.
    @Published public var proxyLocation: URL? {
        didSet { defaults.set(proxyLocation?.path, forKey: ProxyStore.locationDefaultsKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        proxyPreset = defaults.data(forKey: "proxyPreset").flatMap { try? JSONDecoder().decode(ProxyPreset.self, from: $0) }
            ?? .standard
        autoCreateProxies = defaults.bool(forKey: "autoCreateProxies")
        proxyLocation = defaults.string(forKey: ProxyStore.locationDefaultsKey).map { URL(fileURLWithPath: $0) }
    }

    private func save<Value: Encodable>(_ value: Value, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

public extension Notification.Name {
    /// Proxies were created or deleted (object: nil). Playback rebuilds to pick them up.
    static let splicewrightProxiesChanged = Notification.Name("SplicewrightProxiesChanged")
}
