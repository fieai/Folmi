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
