import AppKit

extension FolmiModel {
    /// One composer for both the change list and review completion, sharing the same draft.
    func prepareCommitComposer() {
        showSideTab(.changes)
        focusPane(.changes)
        showCommitComposer = true
        paneFocusRequest = PaneFocusRequest(pane: .changes, prefersCommitEditor: true)
    }

    /// The first press reveals the draft; an unseen generated message must never be committed by a shortcut.
    func handleCommitShortcut() {
        guard hasSnapshot, !busy else { return }
        guard showCommitComposer, paneLayout.sideTab == .changes, paneLayout.isShown(.changes) else {
            prepareCommitComposer()
            return
        }
        guard canCommit else { NSSound.beep(); return }
        commit()
    }
}
