import AppKit
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
