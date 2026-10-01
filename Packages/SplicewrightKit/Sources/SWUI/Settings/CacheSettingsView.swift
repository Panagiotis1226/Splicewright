import AppKit
import SwiftUI
import SWCore
import SWMedia

/// Settings ▸ Media Cache: what Splicewright keeps on disk, and deleting all or part of it.
struct CacheSettingsView: View {
    @State private var usage: [CacheCategory: CacheUsage] = [:]
    @State private var selected: Set<CacheCategory> = []
    @State private var proxyRecords: [ProxyRecord] = []
    @State private var selectedProxies: Set<String> = []
    @State private var showsProxyFiles = false
    @State private var olderThanDays = 30
    @State private var confirmation: Confirmation?
    @State private var lastResult: String?
    @State private var isWorking = false

    private struct Confirmation: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
        var action: () -> Int64
    }

    var body: some View {
        Form {
            Section("Caches") {
                ForEach(CacheCategory.allCases) { category in
                    HStack(alignment: .firstTextBaseline) {
                        Toggle(isOn: binding(category)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.displayName)
                                Text(category.deletionNote).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(summary(usage[category])).monospacedDigit().foregroundStyle(.secondary)
                        Button { reveal(category) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                    }
                }
                HStack {
                    Text("Total: \(Self.bytes(usage.values.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete Selected…") { confirmDelete(selected) }
                        .disabled(selected.isEmpty || isWorking)
                    Button("Delete All Cache…") { confirmDelete(Set(CacheCategory.allCases)) }
                        .disabled(isWorking)
                }
                HStack {
                    Stepper("Delete files older than \(olderThanDays) days", value: $olderThanDays, in: 1...365)
                    Spacer()
                    Button("Delete Old Files…") { confirmOld() }.disabled(isWorking)
                }
                if let lastResult {
                    Text(lastResult).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                DisclosureGroup("Proxy files (\(proxyRecords.count))", isExpanded: $showsProxyFiles) {
                    if proxyRecords.isEmpty {
                        Text("No proxies yet. Right-click clips in the Project panel ▸ Proxy ▸ Create Proxies.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Table(proxyRecords, selection: $selectedProxies) {
                            TableColumn("Source") { record in
                                HStack {
                                    Text(record.sourceName)
                                    if !FileManager.default.fileExists(atPath: record.sourcePath) {
                                        Text("source missing").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                            TableColumn("Size") { Text("\($0.width)×\($0.height)") }.width(90)
                            TableColumn("On Disk") { Text(Self.bytes($0.bytes)) }.width(80)
                            TableColumn("Created") { Text($0.created, style: .date) }.width(90)
                        }
                        .frame(minHeight: 140)
                        HStack {
                            Spacer()
                            Button("Delete Selected Proxies…") { confirmProxies() }
                                .disabled(selectedProxies.isEmpty || isWorking)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, minHeight: 480)
        .task { await refresh() }
        .alert(item: $confirmation) { confirmation in
            Alert(title: Text(confirmation.title), message: Text(confirmation.detail),
                  primaryButton: .destructive(Text("Delete")) { run(confirmation.action) },
                  secondaryButton: .cancel())
        }
    }

    private func binding(_ category: CacheCategory) -> Binding<Bool> {
        Binding(get: { selected.contains(category) }, set: { on in
            if on { selected.insert(category) } else { selected.remove(category) }
        })
    }

    private func summary(_ usage: CacheUsage?) -> String {
        guard let usage else { return "…" }
        return "\(Self.bytes(usage.bytes)) · \(usage.files) file\(usage.files == 1 ? "" : "s")"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func confirmDelete(_ categories: Set<CacheCategory>) {
        let total = categories.reduce(Int64(0)) { $0 + (usage[$1]?.bytes ?? 0) }
        let names = CacheCategory.allCases.filter(categories.contains).map(\.displayName).joined(separator: ", ")
        var detail = "This frees about \(Self.bytes(total))."
        if categories.contains(.proxies) { detail += " Clips will play at full resolution until you create proxies again." }
        confirmation = Confirmation(title: "Delete \(names)?", detail: detail) {
            CacheManager.shared.delete(categories)
        }
    }

    private func confirmOld() {
        let days = olderThanDays
        confirmation = Confirmation(title: "Delete cache files older than \(days) days?",
                                    detail: "Thumbnails and waveforms are rebuilt when needed; old proxies are removed.") {
            CacheManager.shared.delete(olderThan: days)
        }
    }

    private func confirmProxies() {
        let records = proxyRecords.filter { selectedProxies.contains($0.id) }
        let total = records.reduce(Int64(0)) { $0 + $1.bytes }
        confirmation = Confirmation(title: "Delete \(records.count) proxy file\(records.count == 1 ? "" : "s")?",
                                    detail: "This frees about \(Self.bytes(total)).") {
            CacheManager.shared.delete(proxies: records)
        }
    }

    private func run(_ action: @escaping () -> Int64) {
        isWorking = true
        Task {
            let freed = await Task.detached { action() }.value
            ProxyQueue.shared.proxiesDeleted()
            lastResult = "Freed \(Self.bytes(freed))."
            selected = []
            selectedProxies = []
            isWorking = false
            await refresh()
        }
    }

    private func refresh() async {
        let (usage, records) = await Task.detached {
            (CacheManager.shared.usage(), ProxyStore.shared.records().sorted { $0.created > $1.created })
        }.value
        self.usage = usage
        proxyRecords = records
    }

    private func reveal(_ category: CacheCategory) {
        let folder = CacheManager.shared.directory(for: category)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
