import AppKit
import Combine
import SWCore
import SWMedia

/// Creates proxies one at a time in the background, for every open project.
@MainActor
public final class ProxyQueue: ObservableObject {
    public static let shared = ProxyQueue()

    public enum Status: Equatable {
        case queued
        case running(Double)
        case failed(String)
    }

    /// Jobs by media ID. Finished jobs are removed; failed ones stay until retried.
    @Published public private(set) var jobs: [UUID: Status] = [:]
    /// Changes whenever a proxy is created or deleted, so views showing proxy status refresh.
    @Published public private(set) var revision = 0

    private var pending: [(MediaItem, ProxyPreset)] = []
    private var running: (id: UUID, generator: ProxyGenerator)?
    private let store: ProxyStore

    init(store: ProxyStore = .shared) {
        self.store = store
    }

    public var activeCount: Int { jobs.values.filter { !isFailed($0) }.count }

    /// Progress across the active jobs, 0...1.
    public var overallProgress: Double {
        let active = jobs.values.filter { !isFailed($0) }
        guard !active.isEmpty else { return 0 }
        let done = active.reduce(0.0) { total, status in
            if case .running(let fraction) = status { return total + fraction }
            return total
        }
        return done / Double(active.count)
    }

    private func isFailed(_ status: Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    public func hasProxy(_ item: MediaItem) -> Bool {
        _ = revision
        return store.proxy(for: item) != nil
    }

    public func proxyURL(_ item: MediaItem) -> URL? { store.proxy(for: item) }

    /// Queues proxies for video items that don't have one (or are already queued).
    public func enqueue(_ items: [MediaItem], preset: ProxyPreset) {
        // Stills are drawn straight from the file: nothing to proxy.
        for item in items where item.info.video != nil && !item.info.isStill {
            if let status = jobs[item.id], !isFailed(status) { continue }
            jobs[item.id] = .queued
            pending.append((item, preset))
        }
        startNext()
    }

    public func cancel(_ id: UUID) {
        pending.removeAll { $0.0.id == id }
        if running?.id == id { running?.generator.cancel() }
        jobs[id] = nil
    }

    public func cancelAll() {
        pending.removeAll()
        running?.generator.cancel()
        jobs = [:]
    }

    public func deleteProxies(_ items: [MediaItem]) {
        items.forEach { cancel($0.id) }
        store.deleteProxies(of: items)
        changed()
    }

    /// Called after proxy files were deleted elsewhere (the cache manager).
    public func proxiesDeleted() {
        changed()
    }

    private func changed() {
        revision += 1
        NotificationCenter.default.post(name: .splicewrightProxiesChanged, object: nil)
    }

    private func startNext() {
        guard running == nil, !pending.isEmpty else { return }
        let (item, preset) = pending.removeFirst()
        let generator = ProxyGenerator(store: store)
        running = (item.id, generator)
        jobs[item.id] = .running(0)
        Task { [weak self] in
            do {
                try await generator.makeProxy(for: item, preset: preset) { fraction in
                    Task { @MainActor in
                        guard let self, case .running = self.jobs[item.id] else { return }
                        self.jobs[item.id] = .running(fraction)
                    }
                }
                self?.finish(item.id, error: nil)
            } catch ProxyError.cancelled {
                self?.finish(item.id, error: nil)
            } catch {
                self?.finish(item.id, error: error.localizedDescription)
            }
        }
    }

    private func finish(_ id: UUID, error: String?) {
        running = nil
        if let error {
            AppLog.shared.error("Proxy failed for \(id): \(error)", category: "proxy")
        } else {
            AppLog.shared.info("Proxy finished for \(id)", category: "proxy")
        }
        if let error { jobs[id] = .failed(error) } else { jobs[id] = nil }
        changed()
        startNext()
    }
}
