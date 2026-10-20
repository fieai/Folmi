import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// The terminal card: its tabs and shells, text sent into it, and links clicked in it.
extension FolmiModel {
    /// Pastes the editor selection (whole lines; the caret line when nothing is selected) as `path:start-end` and a
    /// fenced block into the terminal, without pressing Enter.
    func sendEditorSelectionToTerminal(selection: NSRange? = nil) {
        guard snapshot != nil, let editor = editorWorkspace, let document = editor.selectedDocument else { NSSound.beep(); return }
        let state = editor.tabStates[document.id]
        let range = selection ?? NSRange(location: state?.selectionLocation ?? 0, length: state?.selectionLength ?? 0)
        guard let snippet = TerminalSnippet.make(path: document.path, text: document.text, selection: range) else {
            editor.showNotice("选中的是空行，没有发送"); return
        }
        sendTextToTerminal(snippet.text, reference: snippet.reference)
    }

    /// Pastes plain text at the terminal prompt without running it.
    func sendTextToTerminal(_ text: String, reference: String) {
        guard let text = TerminalSnippet.plain(text) else { editorWorkspace?.showNotice("选中的是空白，没有发送"); return }
        if !showTerminal || terminalSession == nil { focusPane(.terminal) }
        pasteIntoTerminal(text, kept: "文字已复制到剪贴板。") { [weak self] in
            self?.record("发送文字到终端", reference)
        }
    }

    /// Pastes any text into the selected terminal tab without pressing Enter.
    func sendTextToTerminal(_ text: String) {
        pasteIntoTerminal(text, kept: "内容已复制到剪贴板。") {}
    }

    /// The one way text reaches the terminal: a bracketed paste into the selected tab, then focus moves there.
    /// When the program there has no bracketed paste, the text goes to the clipboard instead and nothing is typed.
    func pasteIntoTerminal(_ text: String, kept: String, onPasted: @escaping () -> Void) {
        guard let terminal = terminalSession else { return }
        Task {
            // A shell that was just opened turns on bracketed paste once its prompt is ready.
            for _ in 0..<30 where !terminal.acceptsBracketedPaste {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            if terminal.paste(text) {
                onPasted()
                focusPane(.terminal)
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                errorMessage = "终端里当前的程序没有开启括号粘贴，直接发送多行内容可能被逐行执行。" + kept
            }
        }
    }

    /// ⌘-click in a terminal: project files open in the editor at the line, web addresses in the browser,
    /// folders and files outside the project are shown in Finder.
    func openTerminalLink(_ link: String, from session: TerminalSession?) {
        guard let editor = editorWorkspace else { return }
        switch TerminalLinks.resolve(link, root: editor.root, cwd: session?.currentDirectory, projectPaths: browserPaths) {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case let .file(path, line, column):
            guard !busy else { NSSound.beep(); return }
            // A changed file named without a line (an agent's "Update(path)") opens its diff: that is what to check.
            if line == nil, let change = snapshot?.files.first(where: { $0.path == path }) {
                area = change.hasWorking ? .working : .staged
                selectFile(change)
                focusPane(.editor)
                return
            }
            do {
                try editor.reveal(path: path, line: line, column: column)
                content = .editor
                targetDiff(path: path)
                focusPane(.editor)
            } catch { report(error, title: "打开文件失败") }
        case .outside(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .missing(let path):
            NSSound.beep()
            editor.showNotice("找不到文件：\(path)")
        }
    }

    /// ⌘ held over a path in the terminal: after a short pause, a card with the file's change summary or its lines.
    func hoverTerminalLink(_ link: String?, rect: NSRect, in session: TerminalSession) {
        terminalHoverTask?.cancel()
        guard let link else { return }
        terminalHoverTask = Task { [weak self, weak session] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, let session, let preview = await self.terminalLinkPreview(link, from: session),
                  !Task.isCancelled, session.terminalView.hoveredLink == link else { return }
            session.terminalView.showLinkPreview(TerminalLinkPreviewView(preview: preview).environment(\.folmiTheme, self.theme)
                .preferredColorScheme(self.colorScheme), at: rect)
        }
    }

    func terminalLinkPreview(_ link: String, from session: TerminalSession?) async -> TerminalLinkPreview? {
        guard let editor = editorWorkspace,
              case let .file(path, line, _) = TerminalLinks.resolve(link, root: editor.root, cwd: session?.currentDirectory,
                                                                    projectPaths: browserPaths) else { return nil }
        if let change = snapshot?.files.first(where: { $0.path == path }), let repository, !change.isUntracked {
            var diffs: [FileDiff] = []
            if change.hasWorking, let diff = try? await repository.diff(for: change, area: .working) { diffs.append(diff) }
            if change.indexCode != ".", change.indexCode != "?", let diff = try? await repository.diff(for: change, area: .staged) { diffs.append(diff) }
            if line == nil { return TerminalLinkPreview.changed(path: path, diffs: diffs) }
        }
        let url = editor.root.appendingPathComponent(path)
        let text = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1024 * 1024,
                  let data = try? Data(contentsOf: url) else { return nil }
            return EditorWorkspace.readerText(data)
        }.value
        guard let text else { return nil }
        let isNew = snapshot?.files.first(where: { $0.path == path })?.isUntracked == true
        return TerminalLinkPreview.file(path: path, text: text, line: line, summary: isNew ? "新文件" : "未改动")
    }

    /// Types `cd '<folder>'` into the terminal (not run), for a folder or a file's folder in the project.
    func openTerminal(at path: String, isDirectory: Bool) {
        guard let root = repositoryURL else { return }
        let folder = isDirectory ? path : (path as NSString).deletingLastPathComponent
        let target = folder.isEmpty ? root.path : root.appendingPathComponent(folder).path
        if !showTerminal || terminalSession == nil { focusPane(.terminal) }
        sendTextToTerminal("cd '" + target.replacingOccurrences(of: "'", with: "'\\''") + "'")
    }

    func toggleTerminal() {
        showTerminal.toggle()
        if showTerminal { startTerminal(); focusPane(.terminal) }
    }

    func syncTerminalPane() {
        if showTerminal { if paneLayout.closed.contains(.terminal) { paneLayout.closed.remove(.terminal) } }
        else if !paneLayout.closed.contains(.terminal) { paneLayout.close(.terminal) }
    }

    /// Opens this project's terminal tabs the first time: as many as were open last time, with their names.
    func startTerminal() {
        guard let root = repositoryURL else { return }
        if terminals[root.path, default: []].isEmpty {
            let project = savedProject(root.path)
            let names = terminalTabsCleared.contains(root.path) ? [] : project?.terminalTabs ?? []
            let directories = terminalTabsCleared.contains(root.path) ? [] : project?.terminalDirectories ?? []
            terminalTabsCleared.remove(root.path)
            terminals[root.path] = (names.isEmpty ? [""] : names).enumerated().map { index, name in
                makeTerminal(root: root, name: name, directory: directories.indices.contains(index) ? directories[index] : "")
            }
        }
        syncTerminalTabs()
    }

    func makeTerminal(root: URL, name: String, directory: String = "") -> TerminalSession {
        let session = TerminalSession(root: root, environment: commandEnvironment, isDemo: isDemo, name: name, directory: directory)
        session.onOpenLink = { [weak self, weak session] link in self?.openTerminalLink(link, from: session) }
        session.onHoverLink = { [weak self, weak session] link, rect in
            guard let session else { return }
            self?.hoverTerminalLink(link, rect: rect, in: session)
        }
        return session
    }

    func syncTerminalTabs() {
        guard let root = repositoryURL?.path else { terminalTabs = []; terminalSession = nil; return }
        let tabs = terminals[root] ?? []
        if terminalTabs.map(\.id) != tabs.map(\.id) { terminalTabs = tabs }
        let selected = tabs.first { $0.id == selectedTerminals[root] } ?? tabs.first
        if terminalSession !== selected { terminalSession = selected }
        selectedTerminals[root] = selected?.id
    }

    /// Replaces the selected tab's shell; the tab keeps its place and name.
    func restartTerminal() {
        guard let root = repositoryURL, let current = terminalSession,
              let index = terminals[root.path]?.firstIndex(where: { $0 === current }) else { startTerminal(); return }
        current.stop()
        let replacement = makeTerminal(root: root, name: current.name)
        terminals[root.path]?[index] = replacement
        selectedTerminals[root.path] = replacement.id
        syncTerminalTabs()
    }

    func newTerminalTab() {
        guard let root = repositoryURL else { return }
        if !showTerminal { showTerminal = true; startTerminal() }
        let session = makeTerminal(root: root, name: "")
        terminals[root.path, default: []].append(session)
        selectedTerminals[root.path] = session.id
        syncTerminalTabs()
        scheduleSave()
        focusPane(.terminal)
    }

    func selectTerminalTab(_ id: UUID) {
        guard let root = repositoryURL?.path else { return }
        aiTabSelected = false
        selectedTerminals[root] = id
        syncTerminalTabs()
        focusPane(.terminal)
    }

    func renameTerminalTab(_ id: UUID, to name: String) {
        guard let session = terminalTabs.first(where: { $0.id == id }) else { return }
        session.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        scheduleSave()
    }

    /// Ends the tab's shell. Closing the last tab also collapses the terminal card.
    func closeTerminalTab(_ id: UUID) {
        guard let root = repositoryURL?.path, var tabs = terminals[root], let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index).stop()
        terminals[root] = tabs
        if selectedTerminals[root] == id { selectedTerminals[root] = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        syncTerminalTabs()
        if tabs.isEmpty {
            // Reopening starts one fresh tab rather than last session's set.
            terminalTabsCleared.insert(root)
            showTerminal = false
        }
        scheduleSave()
    }
}
