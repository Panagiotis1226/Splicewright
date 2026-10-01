import SwiftUI
import SWCore
import SWMedia

/// Bins on the left, clips on the right (list or icon view). Double-click opens a clip
/// in the Source monitor; files or folders dropped anywhere on the panel are imported.
struct ProjectPanel: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject private var proxies = ProxyQueue.shared
    @ObservedObject private var layouts = WorkspaceStore.shared
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.divider)
            GeometryReader { geometry in
                // The bin list's width is saved in the workspace, in points.
                SplitPane(.horizontal, fraction: binsFraction(width: geometry.size.width), minFirst: 100, minSecond: 200) {
                    BinList(workspace: workspace)
                } second: {
                    Group {
                        if workspace.project.media.isEmpty {
                            emptyState
                        } else if workspace.projectViewMode == .list {
                            MediaTable(workspace: workspace)
                        } else {
                            MediaGrid(workspace: workspace)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            statusBar
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, lineWidth: 2).padding(2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            workspace.importFiles(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { workspace.isImporterPresented = true } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import media (⌘I)")
            Button { workspace.newBin() } label: {
                Label("New Bin", systemImage: "folder.badge.plus")
            }
            .help("New bin (⌘B)")
            Picker("View", selection: $workspace.projectViewMode) {
                Image(systemName: "list.bullet").tag(ProjectViewMode.list)
                Image(systemName: "square.grid.2x2").tag(ProjectViewMode.icons)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 70)
            if workspace.projectViewMode == .icons {
                Slider(value: $workspace.iconSize, in: WorkspaceLayout.iconSizeRange)
                    .controlSize(.mini)
                    .frame(width: 80)
                    .help("Thumbnail size")
            }
            Spacer()
            TextField("Search", text: $workspace.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.system(size: 28)).foregroundStyle(Theme.textSecondary)
            Text("Import media to start").foregroundStyle(Theme.textPrimary)
            Text("Drop .mov or .mp4 files here, or press ⌘I.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            Button("Import…") { workspace.isImporterPresented = true }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binsFraction(width: CGFloat) -> Binding<CGFloat> {
        Binding(get: { CGFloat(layouts.current.projectBinsWidth) / max(width, 1) },
                set: { fraction in layouts.update { $0.projectBinsWidth = Double(fraction * max(width, 1)) } })
    }

    private var statusBar: some View {
        HStack {
            if workspace.isImporting {
                ProgressView().controlSize(.mini)
                Text("Importing…")
            }
            if proxies.activeCount > 0 {
                ProgressView(value: proxies.overallProgress).frame(width: 60).controlSize(.mini)
                Text("Creating proxies (\(proxies.activeCount) left)")
                Button("Cancel") { proxies.cancelAll() }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            }
            Spacer()
            let count = workspace.visibleMedia.count
            Text("\(count) item\(count == 1 ? "" : "s")")
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Theme.panelHeader)
    }
}

// MARK: - Bins

private struct BinList: View {
    @ObservedObject var workspace: WorkspaceController
    @State private var draftName = ""
    @State private var renamingSequenceID: UUID?
    @FocusState private var renameFocused: Bool

    var body: some View {
        List {
            row(title: "All Media", systemImage: "tray.full", isSelected: workspace.showsAllMedia) {
                workspace.selectAllMedia()
            }
            let rootSelected = !workspace.showsAllMedia && workspace.selectedBinID == nil
            row(title: "Project Root", systemImage: "folder", isSelected: rootSelected) {
                workspace.selectBin(nil)
            }
            .dropDestination(for: String.self) { ids, _ in moveDropped(ids, to: nil) }
            ForEach(workspace.project.bins) { bin in
                binRow(bin)
            }
            if !workspace.project.sequences.isEmpty {
                Section("Sequences") {
                    ForEach(workspace.project.sequences) { sequence in
                        sequenceRow(sequence)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.panelBackground)
    }

    @ViewBuilder
    private func binRow(_ bin: Bin) -> some View {
        let selected = !workspace.showsAllMedia && workspace.selectedBinID == bin.id
        if workspace.renamingBinID == bin.id {
            TextField("Bin name", text: $draftName)
                .textFieldStyle(.plain)
                .focused($renameFocused)
                .onAppear {
                    draftName = bin.name
                    renameFocused = true
                }
                .onSubmit { workspace.renameBin(bin.id, to: draftName) }
                .onExitCommand { workspace.renamingBinID = nil }
        } else {
            row(title: bin.name, systemImage: "folder.fill", isSelected: selected) {
                workspace.selectBin(bin.id)
            }
            .contextMenu {
                Button("Rename") { workspace.renamingBinID = bin.id }
                Button("Delete Bin") { workspace.deleteBin(bin.id) }
            }
            .dropDestination(for: String.self) { ids, _ in moveDropped(ids, to: bin.id) }
        }
    }

    @ViewBuilder
    private func sequenceRow(_ sequence: EditSequence) -> some View {
        if renamingSequenceID == sequence.id {
            TextField("Sequence name", text: $draftName)
                .textFieldStyle(.plain)
                .focused($renameFocused)
                .onAppear {
                    draftName = sequence.name
                    renameFocused = true
                }
                .onSubmit {
                    workspace.renameSequence(sequence.id, to: draftName)
                    renamingSequenceID = nil
                }
                .onExitCommand { renamingSequenceID = nil }
        } else {
            row(title: sequence.name, systemImage: "film.stack", isSelected: workspace.activeSequenceID == sequence.id) {
                workspace.openSequence(sequence.id)
            }
            .help(sequence.settings.summary)
            .contextMenu {
                Button("Open in Timeline") { workspace.openSequence(sequence.id) }
                Button("Sequence Settings…") { workspace.sequenceSheet = .edit(sequence.id) }
                Button("Rename") { renamingSequenceID = sequence.id }
                Divider()
                Button("Delete Sequence") { workspace.deleteSequence(sequence.id) }
            }
        }
    }

    private func row(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12))
            .foregroundStyle(isSelected ? Color.white : Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(isSelected ? Theme.accent.opacity(0.55) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    /// Clips are dragged between bins as their UUID strings.
    private func moveDropped(_ ids: [String], to binID: UUID?) -> Bool {
        let uuids = Set(ids.compactMap(UUID.init(uuidString:)))
        guard !uuids.isEmpty else { return false }
        workspace.moveMedia(uuids, toBin: binID)
        return true
    }
}

// MARK: - List view

private struct MediaTable: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject private var proxies = ProxyQueue.shared

    var body: some View {
        Table(workspace.visibleMedia, selection: $workspace.selectedMediaIDs) {
            TableColumn("Name") { item in
                MediaNameCell(item: item)
                    .draggable(item.id.uuidString)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Duration") { item in
                Text(item.info.durationTimecode).font(Theme.smallTimecodeFont)
            }
            .width(min: 80, ideal: 90)
            TableColumn("Frame Rate") { item in
                Text(frameRateText(item.info.video))
            }
            .width(min: 60, ideal: 80)
            TableColumn("Resolution") { item in
                Text(item.info.video.map { "\($0.width)×\($0.height)" } ?? "—")
            }
            .width(min: 70, ideal: 90)
            TableColumn("Codec") { item in
                Text(codecText(item.info.video))
            }
            .width(min: 70, ideal: 110)
            TableColumn("Color") { item in
                ColorCell(item: item)
            }
            .width(min: 70, ideal: 110)
            TableColumn("Audio") { item in
                Text(item.info.audioSummary)
            }
            .width(min: 80, ideal: 130)
            TableColumn("Proxy") { item in
                ProxyStatusCell(item: item, queue: proxies)
            }
            .width(min: 44, ideal: 60)
        }
        .font(.system(size: 11))
        .contextMenu(forSelectionType: UUID.self) { ids in
            MediaContextMenu(workspace: workspace, ids: ids)
        } primaryAction: { ids in
            if let id = ids.first { workspace.openInSource(id) }
        }
        .onDeleteCommand { workspace.removeMedia(workspace.selectedMediaIDs) }
    }

    private func frameRateText(_ video: VideoStreamInfo?) -> String {
        guard let video else { return "—" }
        let rate = video.frameRate?.displayName ?? String(format: "%.2f", video.nominalFPS)
        return video.isVariableFrameRate ? "\(rate) (VFR)" : rate
    }

    private func codecText(_ video: VideoStreamInfo?) -> String {
        guard let video else { return "Audio" }
        if let depth = video.bitDepth { return "\(video.codec.displayName) \(depth)-bit" }
        return video.codec.displayName
    }
}

private struct MediaNameCell: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(MediaLocator.isOnline(item) ? Theme.textSecondary : Theme.offline)
                .frame(width: 14)
            Text(item.name).lineLimit(1)
            if !MediaLocator.isOnline(item) {
                Text("Offline").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.offline)
            } else if !item.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(item.warnings.map(\.message).joined(separator: "\n"))
            }
        }
    }

    private var icon: String {
        switch item.info.kind {
        case .audio: return "waveform"
        case .video, .videoWithAudio: return "film"
        case .empty: return "questionmark.square"
        }
    }
}

private struct ColorCell: View {
    let item: MediaItem

    var body: some View {
        if item.info.video != nil, let color = item.effectiveColor {
            HStack(spacing: 4) {
                Text(item.colorOverride == nil ? color.displayName : "\(color.displayName) (overridden)")
                    .help(item.colorOverride == nil ? "From the file's color tags" : "Set with Interpret Footage")
                if color.dynamicRange.isHDR {
                    Text("HDR")
                        .font(.system(size: 8, weight: .heavy))
                        .padding(.horizontal, 3)
                        .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 2))
                        .foregroundStyle(.black)
                }
            }
        } else {
            Text("—")
        }
    }
}

// MARK: - Icon view

private struct MediaGrid: View {
    @ObservedObject var workspace: WorkspaceController

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: workspace.iconSize, maximum: workspace.iconSize * 1.45),
                                         spacing: 10)], spacing: 10) {
                ForEach(workspace.visibleMedia) { item in
                    MediaTile(item: item, isSelected: workspace.selectedMediaIDs.contains(item.id))
                        .onTapGesture(count: 2) { workspace.openInSource(item.id) }
                        .onTapGesture { workspace.selectedMediaIDs = [item.id] }
                        .contextMenu { MediaContextMenu(workspace: workspace, ids: [item.id]) }
                        .draggable(item.id.uuidString)
                }
            }
            .padding(10)
        }
        .onDeleteCommand { workspace.removeMedia(workspace.selectedMediaIDs) }
    }
}

/// —, a progress bar, ✓ (proxy ready) or ⚠ (failed, with the reason as a tooltip).
private struct ProxyStatusCell: View {
    let item: MediaItem
    @ObservedObject var queue: ProxyQueue

    var body: some View {
        switch queue.jobs[item.id] {
        case .queued?:
            Text("Queued").foregroundStyle(Theme.textSecondary)
        case .running(let fraction)?:
            ProgressView(value: fraction).controlSize(.mini)
        case .failed(let reason)?:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(reason)
        case nil:
            if queue.hasProxy(item) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Proxy ready")
            } else {
                Text("—").foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct MediaTile: View {
    let item: MediaItem
    let isSelected: Bool
    @ObservedObject private var proxies = ProxyQueue.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MediaThumbnail(item: item)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    Text(item.info.durationTimecode)
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 4)
                        .background(.black.opacity(0.6))
                        .padding(4)
                }
                .overlay(alignment: .topLeading) {
                    if item.info.video?.dynamicRange.isHDR == true {
                        Text("HDR").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 3)
                            .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 2))
                            .foregroundStyle(.black).padding(4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if proxies.hasProxy(item) {
                        Text("PROXY").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 3)
                            .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 2))
                            .foregroundStyle(.black).padding(4)
                            .help("This clip has a proxy")
                    }
                }
            Text(item.name).font(.system(size: 11)).lineLimit(1).foregroundStyle(Theme.textPrimary)
        }
        .padding(4)
        .background(isSelected ? Theme.accent.opacity(0.45) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Context menu

private struct MediaContextMenu: View {
    @ObservedObject var workspace: WorkspaceController
    let ids: Set<UUID>

    var body: some View {
        if ids.count == 1, let id = ids.first {
            Button("Open in Source Monitor") { workspace.openInSource(id) }
            Button("New Sequence from Clip") { workspace.newSequence(fromClip: id) }
        }
        Menu("Interpret Footage") {
            Button("Automatic (from file)") { workspace.setColorOverride(nil, for: ids) }
            Divider()
            Button("Rec.709 (SDR)") { workspace.setColorOverride(.rec709, for: ids) }
            Button("Rec.2100 HLG (HDR)") { workspace.setColorOverride(.rec2100HLG, for: ids) }
            Button("Rec.2100 PQ (HDR)") { workspace.setColorOverride(.rec2100PQ, for: ids) }
        }
        .disabled(ids.isEmpty)
        Menu("Move to Bin") {
            Button("Project Root") { workspace.moveMedia(ids, toBin: nil) }
            ForEach(workspace.project.bins) { bin in
                Button(bin.name) { workspace.moveMedia(ids, toBin: bin.id) }
            }
        }
        .disabled(ids.isEmpty)
        Button("Reveal in Finder") { workspace.revealInFinder(ids) }
            .disabled(ids.isEmpty)
        Menu("Proxy") {
            Button("Create Proxies (\(MediaPreferences.shared.proxyPreset.displayName))") { workspace.createProxies(ids) }
            Menu("Create Proxies at") {
                ForEach(ProxyPreset.Resolution.allCases, id: \.self) { resolution in
                    ForEach(ProxyPreset.Codec.allCases, id: \.self) { codec in
                        Button("\(resolution.displayName), \(codec.displayName)") {
                            workspace.createProxies(ids, preset: ProxyPreset(resolution: resolution, codec: codec))
                        }
                    }
                }
            }
            Divider()
            Button("Delete Proxies") { workspace.deleteProxies(ids) }
            Button("Reveal Proxy in Finder") { workspace.revealProxies(ids) }
        }
        .disabled(ids.isEmpty)
        Divider()
        Button("Remove from Project") { workspace.removeMedia(ids) }
            .disabled(ids.isEmpty)
    }
}
