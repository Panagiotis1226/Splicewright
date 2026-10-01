import Foundation
import Testing
@testable import SWCore

@Suite("Workspaces")
struct WorkspaceTests {
    @Test func builtInsAreValidAndDistinct() {
        let builtIns = WorkspaceLayout.builtIns
        #expect(Set(builtIns.map(\.id)).count == builtIns.count)
        #expect(Set(builtIns.map(\.name)).count == builtIns.count)
        for layout in builtIns {
            #expect(layout.clamped() == layout, "\(layout.name) is out of range")
            #expect(layout.isBuiltIn)
        }
        #expect(WorkspaceLayout.assembly.projectViewMode == "icons")
    }

    @Test func clamping() {
        var layout = WorkspaceLayout(name: "X")
        layout.rootSplit = 2
        layout.topSplit = -1
        layout.bottomSplit = .nan
        layout.iconSize = 10_000
        layout.programResolution = 0.3
        layout.sourceTab = "nonsense"
        layout.windowFrame = .init(x: 0, y: 0, width: 10, height: 10)
        let clamped = layout.clamped()
        #expect(clamped.rootSplit == 0.9 && clamped.topSplit == 0.1 && clamped.bottomSplit == 0.1)
        #expect(clamped.iconSize == WorkspaceLayout.iconSizeRange.upperBound)
        #expect(clamped.programResolution == 1 && clamped.sourceTab == "source" && clamped.windowFrame == nil)
    }

    @Test func codableRoundTripAndMissingKeys() throws {
        var layout = WorkspaceLayout.review
        layout.windowFrame = .init(x: 10, y: 20, width: 1400, height: 900)
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(WorkspaceLayout.self, from: data) == layout)
        let sparse = Data(#"{"name":"Old","rootSplit":0.6}"#.utf8)
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: sparse)
        #expect(decoded.name == "Old" && decoded.rootSplit == 0.6 && decoded.topSplit == 0.5 && decoded.snapping)
    }

    @Test func changesAreKeptUntilReset() {
        var library = WorkspaceLibrary()
        #expect(library.current.id == WorkspaceLayout.editing.id)
        library.update { $0.projectViewMode = "icons" }
        #expect(library.current.projectViewMode == "icons")
        #expect(library.hasUnsavedChanges(WorkspaceLayout.editing.id))
        // Switching away and back keeps the change.
        library.select(WorkspaceLayout.assembly.id)
        library.select(WorkspaceLayout.editing.id)
        #expect(library.current.projectViewMode == "icons")
        library.resetToSaved()
        #expect(library.current.projectViewMode == "list")
    }

    @Test func saveChangesAndSaveAsNew() throws {
        var library = WorkspaceLibrary()
        library.update { $0.rootSplit = 0.7 }
        library.saveChanges()
        #expect(!library.hasUnsavedChanges(library.currentID))
        library.resetToSaved()
        #expect(library.current.rootSplit == 0.7)

        library.update { $0.bottomSplit = 0.6 }
        let id = library.saveAsNew(named: "Editing")
        #expect(library.currentID == id)
        #expect(library.current.name == "Editing 2", "names stay unique")
        #expect(library.current.bottomSplit == 0.6)
        // The original keeps its unsaved change separately.
        #expect(library.layout(WorkspaceLayout.editing.id)?.bottomSplit == 0.6)
    }

    @Test func renameDuplicateDeleteMoveRestore() throws {
        var library = WorkspaceLibrary()
        let review = WorkspaceLayout.review.id
        library.rename(review, to: "Assembly")
        #expect(library.layout(review)?.name == "Assembly 2")
        let duplicated = library.duplicate(review)
        let copy = try #require(duplicated)
        #expect(library.saved.map(\.id).firstIndex(of: copy) == library.saved.map(\.id).firstIndex(of: review)! + 1)
        library.select(copy)
        library.delete(copy)
        #expect(library.currentID != copy && library.layout(copy) == nil)
        library.move(from: IndexSet(integer: 0), to: library.saved.count)
        #expect(library.saved.last?.id == WorkspaceLayout.editing.id)
        for layout in library.saved { library.delete(layout.id) }
        #expect(library.saved.count == 1, "the last workspace stays")
        library.restoreBuiltIns()
        #expect(Set(WorkspaceLayout.builtIns.map(\.id)).isSubset(of: Set(library.saved.map(\.id))))
        #expect(library.layout(review)?.name == "Review")
    }
}
