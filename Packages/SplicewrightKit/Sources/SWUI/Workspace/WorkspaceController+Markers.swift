import AppKit
import SWCore
import UniformTypeIdentifiers

/// Sequence markers (Timeline/Program), clip markers (Source monitor), and chapter export.
extension WorkspaceController {
    /// M, ⇧M and ⌘⇧M. In the Source monitor they work on the clip's markers.
    func handleMarkerShortcut(_ action: ShortcutAction) -> Bool {
        let inSource = (activePanel == .source || activePanel == .project) && sourceMonitor.mediaID != nil
        switch action {
        case .addMarker:
            if inSource { addSourceMarker() } else { addMarker() }
        case .nextMarker, .previousMarker:
            let next = action == .nextMarker
            if inSource {
                goToSourceMarker(next: next)
            } else {
                goToMarker(next: next)
            }
        default:
            return false
        }
        return true
    }

    // MARK: - Sequence markers

    /// Adds a marker at the playhead. Pressing M again on a marker opens it for editing, as
    /// double-pressing M does in Premiere.
    func addMarker() {
        guard let sequence = activeSequence else { return }
        let frame = playheadFrame
        if let existing = sequence.markers.first(where: { $0.frame == frame }) {
            editingMarkerID = existing.id
            return
        }
        var created: UUID?
        editSequence("Add Marker") { sequence, _ in created = sequence.addMarker(at: frame) }
        selectedMarkerID = created
    }

    func updateMarker(_ id: UUID, _ actionName: String, _ change: (inout Marker) -> Void) {
        editSequence(actionName) { sequence, _ in sequence.updateMarker(id, change) }
    }

    func deleteMarkers(_ ids: Set<UUID>) {
        editSequence(ids.count == 1 ? "Delete Marker" : "Delete Markers") { sequence, _ in sequence.deleteMarkers(ids) }
        if let selected = selectedMarkerID, ids.contains(selected) { selectedMarkerID = nil }
    }

    func clearAllMarkers() {
        guard let ids = activeSequence.map({ Set($0.markers.map(\.id)) }), !ids.isEmpty else { return }
        editSequence("Clear All Markers") { sequence, _ in sequence.deleteMarkers(ids) }
        selectedMarkerID = nil
    }

    func goToMarker(next: Bool) {
        guard let sequence = activeSequence else { return }
        let frame = playheadFrame
        guard let marker = next ? sequence.nextMarker(after: frame) : sequence.previousMarker(before: frame) else { return }
        program.seek(toFrame: marker.frame)
        selectedMarkerID = marker.id
    }

    // MARK: - Clip markers

    func addSourceMarker() {
        guard let id = sourceMonitor.mediaID else { return }
        let time = sourceMonitor.currentFrameTime
        document?.perform("Add Marker", undoManager: undoManager) { project in
            project.updateSourceMarkers(of: id) { markers in
                if !markers.contains(where: { $0.time == time }) { markers.append(SourceMarker(time: time)) }
            }
        }
    }

    func deleteSourceMarker(_ markerID: UUID, of mediaID: UUID) {
        document?.perform("Delete Marker", undoManager: undoManager) { project in
            project.updateSourceMarkers(of: mediaID) { $0.removeAll { $0.id == markerID } }
        }
    }

    private func goToSourceMarker(next: Bool) {
        guard let markers = sourceItem?.markers, !markers.isEmpty else { return }
        let now = sourceMonitor.currentFrameTime
        let target = next ? markers.first { $0.time > now } : markers.last { $0.time < now }
        if let target { sourceMonitor.seek(to: target.time) }
    }

    // MARK: - Export

    func exportChapters() {
        guard let sequence = activeSequence else { return }
        let chapters = Chapters.chapters(from: sequence.markers, rate: sequence.rate)
        let text = Chapters.youTubeText(chapters)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let alert = NSAlert()
        alert.messageText = "\(chapters.count) chapter\(chapters.count == 1 ? "" : "s") copied"
        alert.informativeText = (Chapters.youTubeWarning(for: chapters).map { $0 + "\n\n" } ?? "")
            + "Paste them into the video's YouTube description:\n\n" + text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Save as Text File…")
        if alert.runModal() == .alertSecondButtonReturn {
            save(text, name: "\(sequence.name) Chapters", type: .plainText)
        }
    }

    func exportMarkersCSV() {
        guard let sequence = activeSequence else { return }
        save(Chapters.csv(sequence.markers, rate: sequence.rate), name: "\(sequence.name) Markers",
             type: .commaSeparatedText)
    }

    private func save(_ text: String, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
