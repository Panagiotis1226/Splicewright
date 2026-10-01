import SwiftUI
import SWCore
import SWPlayback

extension MarkerColor {
    var swatch: Color {
        let rgb = self.rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// Every sequence marker, like Premiere's Markers panel: click to jump, double-click to edit,
/// filter by color.
struct MarkersPanel: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var engine: PlaybackEngine
    @State private var colors: Set<MarkerColor> = Set(MarkerColor.allCases)
    @State private var search = ""

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        engine = workspace.program
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Search markers", text: $search).textFieldStyle(.roundedBorder).controlSize(.small)
                ForEach(MarkerColor.allCases, id: \.self) { color in
                    Button { toggle(color) } label: {
                        Circle().fill(color.swatch.opacity(colors.contains(color) ? 1 : 0.2)).frame(width: 10, height: 10)
                    }
                    .buttonStyle(.plain)
                    .help("Show \(color.displayName) markers")
                }
                Button { workspace.addMarker() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add a marker at the playhead (M)")
            }
            .padding(6)
            Divider()
            if let sequence = workspace.activeSequence, !sequence.markers.isEmpty {
                let shown = sequence.markers.filter { marker in
                    colors.contains(marker.color) && (search.isEmpty || marker.name.localizedCaseInsensitiveContains(search)
                        || marker.comment.localizedCaseInsensitiveContains(search))
                }
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(shown) { marker in row(marker, rate: sequence.rate) }
                    }
                    .padding(4)
                }
            } else {
                Text("No markers. Press M to add one at the playhead.")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.system(size: 11))
    }

    private func row(_ marker: Marker, rate: FrameRate) -> some View {
        let selected = workspace.selectedMarkerID == marker.id
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(marker.color.swatch).frame(width: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(Timecode(frame: marker.frame, rate: rate).description)
                        .font(Theme.smallTimecodeFont).foregroundStyle(Theme.timecode)
                    if marker.duration > 0 {
                        Text("· \(Timecode(frame: marker.duration, rate: rate).description)")
                            .font(Theme.smallTimecodeFont).foregroundStyle(Theme.textSecondary)
                    }
                    if marker.isChapter {
                        Image(systemName: "list.bullet.rectangle").foregroundStyle(Theme.textSecondary).help("Chapter")
                    }
                }
                Text(marker.title).foregroundStyle(marker.name.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                if !marker.comment.isEmpty {
                    Text(marker.comment).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.editingMarkerID = marker.id }
        .simultaneousGesture(TapGesture().onEnded {
            workspace.selectedMarkerID = marker.id
            engine.seek(toFrame: marker.frame)
        })
        .contextMenu {
            Button("Edit Marker…") { workspace.editingMarkerID = marker.id }
            Button("Delete Marker") { workspace.deleteMarkers([marker.id]) }
        }
    }

    private func toggle(_ color: MarkerColor) {
        if colors.contains(color) { colors.remove(color) } else { colors.insert(color) }
        if colors.isEmpty { colors = Set(MarkerColor.allCases) }
    }
}

/// Edit a marker: name, comment, color, duration, and whether it's a chapter.
struct MarkerSheet: View {
    @ObservedObject var workspace: WorkspaceController
    let markerID: UUID
    @State private var name = ""
    @State private var comment = ""
    @State private var color = MarkerColor.green
    @State private var durationText = ""
    @State private var isChapter = false

    private var rate: FrameRate { workspace.activeSequence?.rate ?? .fps30 }
    private var marker: Marker? { workspace.activeSequence?.marker(markerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Marker").font(.headline)
            if let marker {
                Form {
                    TextField("Name", text: $name)
                    LabeledContent("In") {
                        Text(Timecode(frame: marker.frame, rate: rate).description).font(Theme.smallTimecodeFont)
                    }
                    TextField("Duration", text: $durationText).font(Theme.smallTimecodeFont)
                    Picker("Color", selection: $color) {
                        ForEach(MarkerColor.allCases, id: \.self) { color in
                            Label { Text(color.displayName) } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(color.swatch)
                            }
                            .tag(color)
                        }
                    }
                    Toggle("Chapter marker (YouTube chapters and chapter marks in exports)", isOn: $isChapter)
                    TextField("Comments", text: $comment, axis: .vertical).lineLimit(3...6)
                }
            }
            HStack {
                Button("Delete", role: .destructive) {
                    workspace.deleteMarkers([markerID])
                    workspace.editingMarkerID = nil
                }
                Spacer()
                Button("Cancel") { workspace.editingMarkerID = nil }.keyboardShortcut(.cancelAction)
                Button("OK", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            guard let marker else { return }
            name = marker.name
            comment = marker.comment
            color = marker.color
            isChapter = marker.isChapter
            durationText = Timecode(frame: marker.duration, rate: rate).description
        }
    }

    private func save() {
        let duration = Timecode(string: durationText, rate: rate)?.frameNumber(rate: rate)
        workspace.updateMarker(markerID, "Edit Marker") { marker in
            marker.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            marker.comment = comment
            marker.color = color
            marker.isChapter = isChapter
            if let duration { marker.duration = duration }
        }
        workspace.selectedMarkerID = markerID
        workspace.editingMarkerID = nil
    }
}
