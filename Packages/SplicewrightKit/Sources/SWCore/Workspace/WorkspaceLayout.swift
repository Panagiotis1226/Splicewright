import Foundation

/// A saved arrangement of the editing window, like Premiere's workspaces: panel sizes,
/// which tabs show, view options and the window's frame. Pure data, so it's tested on Linux.
public struct WorkspaceLayout: Sendable, Hashable, Codable, Identifiable {
    public struct Rect: Sendable, Hashable, Codable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public var id: UUID
    public var name: String
    /// Monitors (top) vs Project/Timeline (bottom), as the top's share of the height.
    public var rootSplit: Double = 0.52
    /// Source vs Program, as the Source's share of the width.
    public var topSplit: Double = 0.5
    /// Project vs Timeline, as the Project panel's share of the width.
    public var bottomSplit: Double = 0.33
    /// Width of the Project panel's bin list, in points.
    public var projectBinsWidth: Double = 160
    /// The tab showing in the Source panel group: "source", "effectControls" or "effects".
    public var sourceTab: String = "source"
    /// "list" or "icons".
    public var projectViewMode: String = "list"
    /// Icon view tile width, in points.
    public var iconSize: Double = 150
    /// Timeline zoom, in points per frame.
    public var timelineZoom: Double = 3
    public var snapping: Bool = true
    /// Program monitor playback resolution: 1, 0.5 or 0.25.
    public var programResolution: Double = 1
    public var showsClipping: Bool = false
    public var showsSafeMargins: Bool = false
    public var useProxies: Bool = false
    /// nil keeps the window where it is.
    public var windowFrame: Rect?

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    public static let splitRange: ClosedRange<Double> = 0.1...0.9
    public static let binsWidthRange: ClosedRange<Double> = 100...400
    public static let iconSizeRange: ClosedRange<Double> = 90...320
    public static let zoomRange: ClosedRange<Double> = 0.02...40

    /// The layout with every value in its valid range.
    public func clamped() -> WorkspaceLayout {
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
        }
        var copy = self
        copy.rootSplit = clamp(rootSplit, Self.splitRange)
        copy.topSplit = clamp(topSplit, Self.splitRange)
        copy.bottomSplit = clamp(bottomSplit, Self.splitRange)
        copy.projectBinsWidth = clamp(projectBinsWidth, Self.binsWidthRange)
        copy.iconSize = clamp(iconSize, Self.iconSizeRange)
        copy.timelineZoom = clamp(timelineZoom, Self.zoomRange)
        if ![1, 0.5, 0.25].contains(programResolution) { copy.programResolution = 1 }
        if !["source", "effectControls", "effects"].contains(sourceTab) { copy.sourceTab = "source" }
        if !["list", "icons"].contains(projectViewMode) { copy.projectViewMode = "list" }
        if let frame = windowFrame, !(frame.width >= 400 && frame.height >= 300) { copy.windowFrame = nil }
        return copy
    }

    /// Files from older versions (or hand edits) may lack keys; missing ones take defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WorkspaceLayout(name: "")
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Workspace"
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        rootSplit = try value(.rootSplit, defaults.rootSplit)
        topSplit = try value(.topSplit, defaults.topSplit)
        bottomSplit = try value(.bottomSplit, defaults.bottomSplit)
        projectBinsWidth = try value(.projectBinsWidth, defaults.projectBinsWidth)
        sourceTab = try value(.sourceTab, defaults.sourceTab)
        projectViewMode = try value(.projectViewMode, defaults.projectViewMode)
        iconSize = try value(.iconSize, defaults.iconSize)
        timelineZoom = try value(.timelineZoom, defaults.timelineZoom)
        snapping = try value(.snapping, defaults.snapping)
        programResolution = try value(.programResolution, defaults.programResolution)
        showsClipping = try value(.showsClipping, defaults.showsClipping)
        showsSafeMargins = try value(.showsSafeMargins, defaults.showsSafeMargins)
        useProxies = try value(.useProxies, defaults.useProxies)
        windowFrame = try container.decodeIfPresent(Rect.self, forKey: .windowFrame)
    }

    // MARK: - Built-ins (stable IDs so they can be restored)

    public static let editing = WorkspaceLayout(id: UUID(uuidString: "0E0E0E0E-0000-4000-8000-000000000001")!,
                                                name: "Editing")

    public static let assembly: WorkspaceLayout = {
        var layout = WorkspaceLayout(id: UUID(uuidString: "0E0E0E0E-0000-4000-8000-000000000002")!, name: "Assembly")
        layout.rootSplit = 0.4
        layout.bottomSplit = 0.55
        layout.projectViewMode = "icons"
        layout.iconSize = 170
        return layout
    }()

    public static let effects: WorkspaceLayout = {
        var layout = WorkspaceLayout(id: UUID(uuidString: "0E0E0E0E-0000-4000-8000-000000000003")!, name: "Effects")
        layout.sourceTab = "effects"
        layout.topSplit = 0.4
        layout.bottomSplit = 0.25
        return layout
    }()

    public static let review: WorkspaceLayout = {
        var layout = WorkspaceLayout(id: UUID(uuidString: "0E0E0E0E-0000-4000-8000-000000000004")!, name: "Review")
        layout.rootSplit = 0.62
        layout.topSplit = 0.3
        layout.showsSafeMargins = true
        return layout
    }()

    public static let builtIns: [WorkspaceLayout] = [editing, assembly, effects, review]

    public var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }
}

/// The user's workspaces: the saved versions, the current one, and unsaved changes to each.
/// Changes to the current workspace are kept automatically (like Premiere); "Reset to Saved
/// Layout" goes back to the saved version.
public struct WorkspaceLibrary: Sendable, Hashable, Codable {
    public private(set) var saved: [WorkspaceLayout]
    /// Changes made since each workspace was last saved.
    public private(set) var live: [UUID: WorkspaceLayout]
    public private(set) var currentID: UUID

    public init() {
        saved = WorkspaceLayout.builtIns
        live = [:]
        currentID = WorkspaceLayout.editing.id
    }

    /// The current workspace as it is now (with unsaved changes).
    public var current: WorkspaceLayout {
        live[currentID] ?? saved.first { $0.id == currentID } ?? saved.first ?? .editing
    }

    public func hasUnsavedChanges(_ id: UUID) -> Bool {
        guard let changed = live[id], let original = saved.first(where: { $0.id == id }) else { return false }
        return changed != original
    }

    public func layout(_ id: UUID) -> WorkspaceLayout? {
        live[id] ?? saved.first { $0.id == id }
    }

    public mutating func select(_ id: UUID) {
        guard saved.contains(where: { $0.id == id }) else { return }
        currentID = id
    }

    /// Records a change to the current workspace (kept until reset).
    public mutating func update(_ change: (inout WorkspaceLayout) -> Void) {
        var layout = current
        change(&layout)
        layout.id = currentID
        layout.name = current.name
        live[currentID] = layout.clamped()
    }

    /// Saves the current layout as a new workspace and switches to it.
    @discardableResult
    public mutating func saveAsNew(named name: String) -> UUID {
        var layout = current
        layout.id = UUID()
        layout.name = uniqueName(name)
        saved.append(layout.clamped())
        currentID = layout.id
        return layout.id
    }

    /// Makes the current layout the workspace's saved version.
    public mutating func saveChanges() {
        guard let index = saved.firstIndex(where: { $0.id == currentID }) else { return }
        saved[index] = current
        live[currentID] = nil
    }

    /// Throws away unsaved changes to the current workspace.
    public mutating func resetToSaved() {
        live[currentID] = nil
    }

    public mutating func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[index].name = uniqueName(trimmed, except: id)
        live[id]?.name = saved[index].name
    }

    @discardableResult
    public mutating func duplicate(_ id: UUID) -> UUID? {
        guard let source = layout(id) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = uniqueName("\(source.name) Copy")
        saved.insert(copy, at: (saved.firstIndex { $0.id == id } ?? saved.count - 1) + 1)
        return copy.id
    }

    /// Deletes a workspace. The last one can't be deleted.
    public mutating func delete(_ id: UUID) {
        guard saved.count > 1, let index = saved.firstIndex(where: { $0.id == id }) else { return }
        saved.remove(at: index)
        live[id] = nil
        if currentID == id { currentID = saved[min(index, saved.count - 1)].id }
    }

    public mutating func move(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { saved[$0] }
        var remaining = saved.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(insertAt, 0), remaining.count))
        saved = remaining
    }

    /// Puts back any built-in workspace that was deleted, and resets the built-ins to their
    /// original layouts.
    public mutating func restoreBuiltIns() {
        for builtIn in WorkspaceLayout.builtIns {
            live[builtIn.id] = nil
            if let index = saved.firstIndex(where: { $0.id == builtIn.id }) {
                saved[index] = builtIn
            } else {
                saved.append(builtIn)
            }
        }
    }

    private func uniqueName(_ name: String, except id: UUID? = nil) -> String {
        let taken = Set(saved.filter { $0.id != id }.map(\.name))
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name) \(suffix)") { suffix += 1 }
        return "\(name) \(suffix)"
    }
}
