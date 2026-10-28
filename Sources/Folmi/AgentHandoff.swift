import AppKit
import Foundation
import FolmiCore

/// Selections handed to the agent (⌘J, 交给 Codex) or asked about (⌘L): what is selected where, turned into an
/// attachment with its place (`path:12-30`, a hunk, terminal text). Nothing is sent; the user adds a sentence first.
extension FolmiModel {
    /// The agent the buttons name: the open conversation's, else the default one.
    var agentTitle: String { (agentSession?.agent ?? AgentKind(rawValue: aiSettings.defaultAgent) ?? .codex).title }

    /// Adds attachments to the AI tab's composer and moves the keyboard there. The same text twice is kept once.
    func attachToAgent(_ items: [AgentContext]) {
        for item in items where !agentContext.contains(where: { $0.title == item.title && $0.text == item.text }) {
            agentContext.append(item)
        }
        openAgentTab()
        agentComposerFocus += 1
    }

    /// ⌘⇧J: the AI tab with the keyboard in its composer.
    func focusAgentComposer() {
        openAgentTab()
        agentComposerFocus += 1
    }

    // MARK: Editor

    /// The editor's selection, or the whole file when nothing is selected.
    func editorSelectionContext(path: String, text: String, range: NSRange) -> AgentContext? {
        let file = repositoryURL?.appendingPathComponent(path)
        if range.length == 0 {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AgentContext(title: "\(path)（整个文件）", text: String(text.prefix(40_000)), uri: file?.absoluteString)
        }
        guard let snippet = TerminalSnippet.make(path: path, text: text, selection: range) else { return nil }
        let lines = snippet.reference.dropFirst(path.count + 1)
        return AgentContext(title: snippet.reference, text: String(snippet.text.prefix(40_000)),
                            uri: file.map { "\($0.absoluteString)#L\(lines)" })
    }

    func editorSelectionAI(_ action: EditorSelectionAction, path: String, text: String, range: NSRange) {
        guard let context = editorSelectionContext(path: path, text: text, range: range) else {
            editorWorkspace?.showNotice("选中的是空白"); return
        }
        switch action {
        case .handToAgent: attachToAgent([context])
        case .ask(let question): askAbout(context, question: question)
        }
    }

    /// The Markdown reader's selection: the text as read, with its source lines.
    func readerSelectionAI(_ action: EditorSelectionAction, path: String, first: Int, last: Int, text: String) {
        guard let plain = TerminalSnippet.plain(text) else { return }
        let lines = first == last ? "\(first)" : "\(first)-\(last)"
        let file = repositoryURL?.appendingPathComponent(path)
        let context = AgentContext(title: "\(path):\(lines)", text: String(plain.prefix(40_000)), uri: file.map { "\($0.absoluteString)#L\(lines)" })
        switch action {
        case .handToAgent: attachToAgent([context])
        case .ask(let question): askAbout(context, question: question)
        }
    }

    /// The small AI card about one attachment; a preset question is asked right away.
    func askAbout(_ context: AgentContext, question: String?) {
        if let finding = SecretScan.findings(in: context.text).first {
            aiAssist = AIAssistState(mode: .ask, source: context.title, input: "", error: "内容疑似含密钥（\(finding)），没有发给 AI。")
            return
        }
        aiAssist = AIAssistState(mode: .ask, source: context.title, input: context.text)
        if let question { runAssist(question: question) }
    }

    // MARK: Diffs

    /// Changed lines picked with the line checkboxes on the diff or all-changes page, one attachment per file.
    func diffSelectionContexts() -> [AgentContext] {
        switch content {
        case .diff:
            return (fileDiffs.isEmpty ? [fileDiff].compactMap { $0 } : fileDiffs).compactMap { diff in
                Self.diffContext(diff, lines: selectedLines[diff.file.path] ?? [])
            }
        case .allChanges:
            return allChanges.compactMap { Self.diffContext($0, lines: allChangesSelection[$0.allChangesKey] ?? []) }
        default:
            return []
        }
    }

    /// A hunk (or the lines picked in it) from 交给 Codex on its header.
    func handHunkToAgent(_ hunk: DiffHunk, in diff: FileDiff) {
        let picked = content == .allChanges ? allChangesSelected(in: hunk, of: diff)
            : (selectedLines[diff.file.path] ?? []).intersection(hunk.lines.map(\.id))
        let number = (diff.hunks.firstIndex { $0.id == hunk.id } ?? 0) + 1
        let context = picked.isEmpty
            ? AgentContext(title: "\(diff.file.path) 第 \(number) 处改动", text: Self.patchText([hunk], lines: nil))
            : Self.diffContext(diff, lines: picked)
        if let context { attachToAgent([context]) }
    }

    nonisolated static func diffContext(_ diff: FileDiff, lines: Set<Int>) -> AgentContext? {
        guard !lines.isEmpty else { return nil }
        let hunks = diff.hunks.filter { hunk in hunk.lines.contains { lines.contains($0.id) } }
        let count = hunks.flatMap(\.lines).filter { lines.contains($0.id) && ($0.kind == .addition || $0.kind == .deletion) }.count
        guard count > 0 else { return nil }
        return AgentContext(title: "\(diff.file.path) 选中 \(count) 行的改动", text: patchText(hunks, lines: lines))
    }

    /// Hunk headers and `+` / `-` lines as in a patch; with `lines`, only those changed lines.
    nonisolated static func patchText(_ hunks: [DiffHunk], lines: Set<Int>?) -> String {
        hunks.map { hunk in
            let body = hunk.lines.compactMap { line -> String? in
                switch line.kind {
                case .addition: return lines == nil || lines!.contains(line.id) ? "+" + line.text : nil
                case .deletion: return lines == nil || lines!.contains(line.id) ? "-" + line.text : nil
                case .context: return lines == nil ? " " + line.text : nil
                case .meta: return nil
                }
            }
            return ([hunk.header] + body).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: ⌘J / ⌘L

    private var focusedEditor: EditorTextView? { NSApp.keyWindow?.firstResponder as? EditorTextView }

    private var terminalHasFocus: Bool {
        guard let view = terminalSession?.terminalView, let responder = NSApp.keyWindow?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// What ⌘J and ⌘L take when no editor has the keyboard: the focused terminal's selection, else lines picked in
    /// a diff, else (`whole`) the open diff or file.
    func focusedContexts(whole: Bool) -> [AgentContext] {
        if terminalHasFocus, let text = terminalSelection, TerminalSnippet.plain(text) != nil {
            return [AgentContext(title: "终端选中内容", text: String(text.prefix(40_000)))]
        }
        let picked = diffSelectionContexts()
        if !picked.isEmpty || !whole { return picked }
        if content == .diff, let diff = fileDiff {
            return [AgentContext(title: "\(diff.file.path) 的改动", text: String(diff.rawPatch.prefix(40_000)))]
        }
        if content == .editor, let document = editorWorkspace?.selectedDocument,
           let context = editorSelectionContext(path: document.path, text: document.text, range: NSRange(location: 0, length: 0)) {
            return [context]
        }
        return []
    }

    /// ⌘J: the focused editor's selection (else its file), the terminal's, lines picked in a diff or the open diff go
    /// into the agent's composer; with nothing to take, just the composer.
    func handFocusedToAgent() {
        if let editor = focusedEditor, let selectionAI = editor.selectionAI {
            selectionAI(.handToAgent, editor.selectedRange()); return
        }
        if content == .tasks, let task = selectedTask { handTaskToAgent(task); return }
        let items = focusedContexts(whole: true)
        if items.isEmpty { focusAgentComposer() } else { attachToAgent(items) }
    }

    /// ⌘L on a selection: the editor's, the terminal's or picked diff lines. False when there is none, so ⌘L
    /// falls back to the open file or diff.
    func askAboutSelection() -> Bool {
        if let editor = focusedEditor, editor.selectedRange().length > 0, let selectionAI = editor.selectionAI {
            selectionAI(.ask(nil), editor.selectedRange()); return true
        }
        let items = focusedContexts(whole: false)
        guard !items.isEmpty else { return false }
        askAbout(AgentContext(title: items.map(\.title).joined(separator: "、"), text: items.map(\.text).joined(separator: "\n\n")), question: nil)
        return true
    }
}
