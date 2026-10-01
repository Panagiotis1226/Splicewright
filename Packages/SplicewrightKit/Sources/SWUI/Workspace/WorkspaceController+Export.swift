import AppKit
import Combine
import SWCore
import SWExport

/// Export and Interpret Footage actions.
extension WorkspaceController {
    public func requestExport() {
        guard activeSequence != nil else {
            NSSound.beep()
            return
        }
        if exportSession?.state.isRunning != true { exportSession = nil }
        isExportSheetPresented = true
    }

    /// Starts exporting a snapshot of the active sequence; editing can continue meanwhile.
    public func startExport(_ settings: ExportSettings, to url: URL) {
        guard let sequence = activeSequence else { return }
        lastExportSettings = settings
        let session = ExportSession(sequence: sequence, project: project, settings: settings, outputURL: url)
        exportSession = session
        let offline = Set(sequence.allTracks.flatMap { $0.clips.map(\.mediaID) }).intersection(offlineMediaIDs)
        AppLog.shared.info("Export started: \(url.lastPathComponent), \(settings.codec.displayName)"
                           + (offline.isEmpty ? "" : ", \(offline.count) offline file(s) render as Media Offline"),
                           category: "export")
        session.$state
            .receive(on: RunLoop.main)
            .sink { state in
                switch state {
                case .finished(let output): AppLog.shared.info("Export finished: \(output.path)", category: "export")
                case .failed(let reason): AppLog.shared.error("Export failed: \(reason)", category: "export")
                case .cancelled: AppLog.shared.info("Export cancelled", category: "export")
                default: break
                }
            }
            .store(in: &cancellables)
        session.start()
    }

    public func cancelExport() {
        exportSession?.cancel()
    }

    public func dismissExport() {
        if exportSession?.state.isRunning != true { exportSession = nil }
        isExportSheetPresented = false
    }

    /// Interpret Footage: override (or with nil, restore) how clips' colors are read.
    public func setColorOverride(_ color: ColorDescription?, for ids: Set<UUID>) {
        document?.perform("Interpret Footage", undoManager: undoManager) { $0.setColorOverride(color, for: ids) }
    }
}
