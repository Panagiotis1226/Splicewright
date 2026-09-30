import Combine
import SwiftUI
import SWCore
import UniformTypeIdentifiers

public extension UTType {
    /// Must match `UTExportedTypeDeclarations` in the app's Info.plist.
    static let splicewrightProject = UTType(exportedAs: "com.splicewright.project", conformingTo: .package)
}

/// A `.splicewright` package: a directory holding `project.json`.
///
/// Edits go through `perform(_:undoManager:_:)`, which snapshots the whole
/// `Project` value for undo. Registering undo is also what tells SwiftUI the
/// document is dirty and should be autosaved.
public final class ProjectDocument: ReferenceFileDocument {
    public typealias Snapshot = Project

    public static var readableContentTypes: [UTType] { [.splicewrightProject] }

    @Published public private(set) var project: Project

    public init(project: Project = Project()) {
        self.project = project
    }

    public init(configuration: ReadConfiguration) throws {
        guard let wrapper = configuration.file.fileWrappers?[ProjectFileCoder.projectFileName],
              let data = wrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        project = try ProjectFileCoder.decode(data)
    }

    public func snapshot(contentType: UTType) throws -> Project {
        project
    }

    public func fileWrapper(snapshot: Project, configuration: WriteConfiguration) throws -> FileWrapper {
        let file = FileWrapper(regularFileWithContents: try ProjectFileCoder.encode(snapshot))
        file.preferredFilename = ProjectFileCoder.projectFileName
        return FileWrapper(directoryWithFileWrappers: [ProjectFileCoder.projectFileName: file])
    }

    /// Applies an undoable edit. No-op edits register nothing.
    public func perform(_ actionName: String, undoManager: UndoManager?, _ change: (inout Project) -> Void) {
        var updated = project
        change(&updated)
        guard updated != project else { return }
        let previous = project
        project = updated
        registerUndo(restoring: previous, actionName: actionName, undoManager: undoManager)
    }

    /// Applies an edit that should not appear in the undo stack (e.g. relinking moved files).
    public func performWithoutUndo(_ change: (inout Project) -> Void) {
        var updated = project
        change(&updated)
        if updated != project { project = updated }
    }

    private func registerUndo(restoring previous: Project, actionName: String, undoManager: UndoManager?) {
        guard let undoManager else { return }
        // Edits made outside an event (an import finishing, say) would otherwise sit in an
        // automatic group that stays open until the next event; give them their own step.
        let ownsGroup = undoManager.groupingLevel == 0 && !undoManager.isUndoing && !undoManager.isRedoing
        if ownsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { document in
            let current = document.project
            document.project = previous
            document.registerUndo(restoring: current, actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
        if ownsGroup { undoManager.endUndoGrouping() }
    }
}
