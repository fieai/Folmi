import AppKit
import Foundation
import FolmiCore

/// 向左拆分 / 向右拆分 for the editor and terminal cards: their columns, and which one the keyboard works on.
extension FolmiModel {
    /// Why the card cannot take another column right now, for the greyed split button; nil when it can.
    func splitBlockedReason(_ pane: FolmiPane) -> String? {
        switch pane {
        case .editor:
            guard let editor = editorWorkspace else { return "先打开一个项目" }
            if content == .allChanges || content == .history || content == .tasks || content == .calls { return "切到编辑或差异页后可以拆分" }
            if !editor.columns.canSplit { return "最多拆成 \(PaneColumns.limit) 栏" }
            if content == .diff, fileDiffs.isEmpty { return "左侧先选一处改动" }
            if content == .editor, editor.selectedDocumentID == nil { return "先打开一个文件" }
        case .terminal:
            guard let root = repositoryURL?.path, terminalSession != nil else { return "先打开终端" }
            if terminalColumns[root]?.canSplit == false { return "最多拆成 \(PaneColumns.limit) 栏" }
        case .changes:
            return "这一栏不能拆分"
        }
        if splitRoom[pane] == false { return "窗口太窄，放不下再一栏" }
        return nil
    }

    /// ⌘\ and ⌥⌘\: splits the focused card.
    func splitFocused(toRight: Bool) {
        switch paneLayout.focused {
        case .editor: splitEditor(toRight: toRight)
        case .terminal: splitTerminal(toRight: toRight)
        case .changes: NSSound.beep()
        }
    }

    /// The column keyboard focus goes to in a split card; nil when the card is not split.
    func activeColumnID(_ pane: FolmiPane) -> UUID? {
        switch pane {
        case .editor:
            guard let columns = editorWorkspace?.columns, columns.isSplit else { return nil }
            if content == .diff, let diff = columns.columns.first(where: \.isDiff) { return diff.id }
            return columns.activeID
        case .terminal:
            guard let root = repositoryURL?.path, let columns = terminalColumns[root], columns.isSplit else { return nil }
            return columns.activeID
        case .changes: return nil
        }
    }

    /// A click landed in a column of a split card: that column becomes the one the keyboard and commands work on.
    func noteColumnClicked(_ pane: FolmiPane, _ column: UUID) {
        switch pane {
        case .editor:
            guard let editor = editorWorkspace, let index = editor.columns.index(of: column) else { return }
            if editor.columns.columns[index].isDiff {
                if content == .editor { content = .diff }
            } else {
                if editor.columns.activeID != column { editor.columns.activate(column) }
                if content == .diff, editor.columns.hasDiff { content = .editor }
            }
        case .terminal:
            guard let root = repositoryURL?.path, var layout = terminalColumns[root], layout.activeID != column,
                  let index = layout.index(of: column) else { return }
            layout.activate(column)
            terminalColumns[root] = layout
            if let selected = layout.columns[index].selected.flatMap(UUID.init(uuidString:)) { selectedTerminals[root] = selected }
            syncTerminalTabs()
        case .changes: break
        }
    }

    // MARK: Editor

    func markdownSideBySideBlockedReason(column: UUID) -> String? {
        guard let editor = editorWorkspace,
              let pane = editor.columns.columns.first(where: { $0.id == column && !$0.isDiff }),
              let path = pane.selected, NativeCodeEditor.isMarkdownPath(path) else { return "先打开一个 Markdown 文件" }
        if editor.columns.columns.contains(where: { $0.id != column && !$0.isDiff && $0.selected == path }) { return nil }
        return splitBlockedReason(.editor)
    }

    func showMarkdownSideBySide(column: UUID) {
        guard markdownSideBySideBlockedReason(column: column) == nil, let editor = editorWorkspace,
              let sourceIndex = editor.columns.index(of: column),
              let path = editor.columns.columns[sourceIndex].selected else { return }
        var other = editor.columns.columns.first { $0.id != column && !$0.isDiff && $0.selected == path }?.id
        if other == nil {
            splitEditor(toRight: true, tab: path, from: column)
            other = editor.columns.activeID == column ? nil : editor.columns.activeID
        }
        guard let other, let otherIndex = editor.columns.index(of: other) else { return }
        let left = sourceIndex < otherIndex ? column : other
        let right = left == column ? other : column
        editor.setReading(false, column: left)
        editor.setReading(true, column: right)
        editor.columns.activate(left)
        if let line = editor.editorTopLineByColumn[left]?() {
            editor.followEditorScroll(from: left, documentID: path, line: line)
        }
        content = .editor
        focusPane(.editor)
    }

    /// Splits the editor card. On the 编辑 page the file shows in a new column too; on the 差异 page the diff becomes a
    /// column of its own with the file it shows open beside it.
    func splitEditor(toRight: Bool, tab: String? = nil, from column: UUID? = nil) {
        guard let editor = editorWorkspace else { return }
        if let reason = splitBlockedReason(.editor) { NSSound.beep(); editor.showNotice(reason); return }
        let fromDiff = column.flatMap { id in editor.columns.columns.first { $0.id == id }?.isDiff } ?? (content == .diff)
        if fromDiff {
            guard let path = fileDiffs.first?.file.path else { NSSound.beep(); return }
            let target: UUID?
            if editor.columns.hasDiff, let diff = editor.columns.columns.first(where: \.isDiff) {
                target = editor.columns.split(nil, from: diff.id, toRight: toRight, move: false)
            } else {
                // The diff takes the side away from the new column; the open files stay together on the other.
                editor.columns.addDiff(atRight: !toRight)
                target = besideDiff(editor.columns)
            }
            guard let target else { return }
            open(path, line: fileDiffs.first.flatMap(Self.firstChangedLine), in: target)
            return
        }
        let source = column ?? editor.columns.activeID
        guard let index = editor.columns.index(of: source), let tab = tab ?? editor.columns.columns[index].selected else {
            NSSound.beep(); return
        }
        editor.columns.split(tab, from: source, toRight: toRight, move: false)
        content = .editor
        focusPane(.editor)
    }

    func moveEditorTab(_ tab: String, from column: UUID, toRight: Bool) {
        guard let editor = editorWorkspace else { return }
        if !editor.columns.move(tab, from: column, toRight: toRight) { NSSound.beep() }
        focusPane(.editor)
    }

    /// Closes a column; nothing in it closes. Its tabs join the column beside it. Closing the files beside 差异 leaves the
    /// diff on the whole card.
    func closeEditorColumn(_ column: UUID) {
        guard let editor = editorWorkspace, let index = editor.columns.index(of: column) else { return }
        let wasDiff = editor.columns.columns[index].isDiff
        let hadDiff = editor.columns.hasDiff
        editor.columns.merge(column)
        if wasDiff { if content == .diff { content = .editor } }
        else if hadDiff && !editor.columns.hasDiff { content = .diff }
    }

    /// 在旁边编辑 on the diff toolbar: the file opens in the column beside the diff, at the first change.
    /// Without a 差异 column yet the card splits: the diff on the left, the files on the right.
    func editBeside(_ diff: FileDiff) {
        guard let editor = editorWorkspace, !busy else { return }
        if !editor.columns.hasDiff {
            guard splitBlockedReason(.editor) == nil else { editPath(diff.file.path); return }
            editor.columns.addDiff(atRight: false)
        }
        guard let target = besideDiff(editor.columns) else { return }
        open(diff.file.path, line: Self.firstChangedLine(diff), in: target)
    }

    func editDiffPoint(_ point: DiffEditPoint, in diff: FileDiff, renderedText: String? = nil) async {
        guard diff.canEditPoint, !busy, let editor = editorWorkspace, let repository, let root = repositoryURL else { return }
        let startPage = content
        let reviewPage = startPage == .allChanges
        let request = UUID()
        diffEditRequest = request
        let path = diff.file.path
        do {
            // A staged diff uses index line numbers, while the editor always edits the working copy.
            let version: FileVersion = diff.area == .staged ? .object(":" + path) : .worktree(path)
            guard let bytes = try await repository.bytes(of: version, limit: 2 * 1_024 * 1_024),
                  let reference = EditorWorkspace.readerText(bytes) else { throw FolmiError.staleSnapshot }
            guard diffEditRequest == request, repositoryURL == root, content == startPage, !busy else { return }
            guard renderedText.map({ $0 == reference }) ?? point.matches(reference),
                  !diff.file.isUntracked || MarkdownDiffPage.normalized(diff.rawPatch) == reference else {
                throw FolmiError.staleSnapshot
            }
            let target = besideDiff(editor.columns) ?? editor.columns.activeID
            try editor.open(path: path, asText: true, in: target)
            if diff.area == .working, let document = editor.selectedDocument, !document.isDirty, document.text != reference {
                editor.reloadCleanDocuments()
            }
            guard let document = editor.selectedDocument, document.preview == nil else {
                throw FolmiError.unsupported("这个文件不能作为文本编辑。")
            }
            let line = DiffEditPoint.translatedLine(point.line, from: reference, into: document.text)
            if reviewPage { followReview(diff) }
            if !editor.columns.hasDiff, editor.columns.canSplit, splitRoom[.editor] != false {
                editor.columns.addDiff(atRight: false)
            }
            if EditorWorkspace.isMarkdownPath(path), editor.isReading(column: target) {
                editor.setReading(false, column: target)
                editor.editorScrollRequests[target] = (path, line - 1)
            }
            try editor.reveal(path: path, line: line)
            diffEditReveal = nil
            diffEditReturn = DiffEditReturn(path: path, area: diff.area, content: reviewPage ? .allChanges : .diff,
                                           fingerprint: diff.fingerprint, hunkID: point.hunk?.id, hunkHeader: point.hunk?.header,
                                           line: point.line, lineID: point.lineID)
            content = .editor
            focusPane(.editor)
        } catch {
            guard diffEditRequest == request, repositoryURL == root, content == startPage else { return }
            report(error, title: "无法编辑这一处")
        }
    }

    func returnToDiffEdit() {
        guard !busy, let origin = diffEditReturn, let root = repositoryURL else { return }
        diffEditReturn = nil
        diffEditReveal = origin
        if origin.content == .allChanges {
            content = .allChanges
            Task {
                await loadAllChanges()
                guard repositoryURL == root, content == .allChanges, diffEditReveal == origin,
                      let diff = allChanges.first(where: { $0.allChangesKey == origin.key }) else { return }
                reviewFileJump = ReviewFileJump(key: origin.key, hunkID: origin.hunk(in: diff)?.id, lineID: origin.rowID(in: diff))
            }
        } else {
            if fileDiffs.contains(where: { $0.allChangesKey == origin.key }) {
                content = .diff
            } else if let file = snapshot?.files.first(where: { $0.path == origin.path }),
                      origin.area == .working ? file.hasWorking : file.hasStaged {
                selectFiles([file.id], in: origin.area)
            } else { showChanges(of: origin.path) }
        }
        focusPane(.editor)
    }

    private func besideDiff(_ columns: PaneColumns) -> UUID? {
        guard let diff = columns.columns.firstIndex(where: \.isDiff),
              let target = columns.neighbour(of: diff, toRight: true) ?? columns.neighbour(of: diff, toRight: false) else { return nil }
        return columns.columns[target].id
    }

    private func open(_ path: String, line: Int?, in column: UUID) {
        guard let editor = editorWorkspace else { return }
        do {
            try editor.open(path: path, in: column)
            if let line { try editor.reveal(path: path, line: line) }
            content = .editor
            focusPane(.editor)
        } catch { report(error, title: "打开文件失败") }
    }

    /// The new-file line (1-based) of the first added or removed line in the diff.
    nonisolated static func firstChangedLine(_ diff: FileDiff) -> Int? {
        guard let hunk = diff.hunks.first,
              let match = hunk.header.range(of: #"\+(\d+)"#, options: .regularExpression),
              let start = Int(hunk.header[match].dropFirst()) else { return nil }
        let context = hunk.lines.prefix { $0.kind == .context || $0.kind == .meta }.filter { $0.kind == .context }.count
        return max(1, start + context)
    }

    // MARK: Terminal

    /// Splits the terminal card. The tab moves to the new column; a column's only tab stays and a new shell opens beside it.
    func splitTerminal(toRight: Bool, tab: UUID? = nil, from column: UUID? = nil) {
        guard let root = repositoryURL else { return }
        if let reason = splitBlockedReason(.terminal) { NSSound.beep(); errorMessage = reason; return }
        syncTerminalTabs()
        guard var layout = terminalColumns[root.path] else { return }
        let source = column ?? layout.activeID
        guard let index = layout.index(of: source) else { return }
        if let id = tab?.uuidString ?? layout.columns[index].selected, layout.columns[index].tabs.count > 1 {
            layout.split(id, from: source, toRight: toRight, move: true)
        } else {
            let session = makeTerminal(root: root, name: "")
            terminals[root.path, default: []].append(session)
            layout.split(session.id.uuidString, from: source, toRight: toRight, move: false)
        }
        commitTerminalColumns(layout, root: root.path)
        focusPane(.terminal)
    }

    func moveTerminalTab(_ tab: UUID, from column: UUID, toRight: Bool) {
        guard let root = repositoryURL?.path, var layout = terminalColumns[root] else { return }
        if !layout.move(tab.uuidString, from: column, toRight: toRight) { NSSound.beep(); return }
        commitTerminalColumns(layout, root: root)
        focusPane(.terminal)
    }

    /// Closes a terminal column; its shells keep running in the column beside it.
    func closeTerminalColumn(_ column: UUID) {
        guard let root = repositoryURL?.path, var layout = terminalColumns[root] else { return }
        layout.merge(column)
        commitTerminalColumns(layout, root: root)
    }

    func resizeColumns(_ pane: FolmiPane, at index: Int, to fraction: Double, minimum: Double) {
        switch pane {
        case .editor: editorWorkspace?.columns.resize(index, to: fraction, minimum: minimum)
        case .terminal:
            guard let root = repositoryURL?.path, var layout = terminalColumns[root] else { return }
            layout.resize(index, to: fraction, minimum: minimum)
            terminalColumns[root] = layout
            scheduleSave()
        case .changes: break
        }
    }
    func equalizeColumns(_ pane: FolmiPane) {
        switch pane {
        case .editor: editorWorkspace?.columns.equalize()
        case .terminal:
            guard let root = repositoryURL?.path, var layout = terminalColumns[root] else { return }
            layout.equalize()
            terminalColumns[root] = layout
            scheduleSave()
        case .changes: break
        }
    }

    private func commitTerminalColumns(_ layout: PaneColumns, root: String) {
        terminalColumns[root] = layout
        selectedTerminals[root] = layout.selected.flatMap(UUID.init(uuidString:)) ?? selectedTerminals[root]
        syncTerminalTabs()
        scheduleSave()
    }
}
