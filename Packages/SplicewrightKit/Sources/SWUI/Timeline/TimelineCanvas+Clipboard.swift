import AppKit

/// Edit ▸ Cut, Copy and Paste (⌘X, ⌘C, ⌘V) while the timeline has focus. They come through
/// the responder chain, so text fields elsewhere keep their own copy and paste.
extension TimelineCanvas: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) {
        workspace.copySelectedClips()
    }

    @objc func cut(_ sender: Any?) {
        workspace.cutSelectedClips()
    }

    @objc func paste(_ sender: Any?) {
        workspace.pasteClips()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)): return workspace.canCopyClips
        case #selector(paste(_:)): return workspace.canPasteClips
        default: return true
        }
    }
}
