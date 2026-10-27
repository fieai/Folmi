import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit
import Darwin
import FolmiCore

struct EditorDocument: Identifiable, Equatable {
    let id: String
    let path: String
    var text: String
    var originalText: String
    var fingerprint: String
    /// Set for a read-only preview tab (pictures, Word, PDF…); its text stays empty and its fingerprint is the file's
    /// size and modification time.
    var preview: FilePreviewKind? = nil
    var isDirty: Bool { text != originalText }
}

enum FileEditorError: LocalizedError, Equatable {
    case unsafePath
    case symbolicLink
    case notRegularFile
    case tooLarge
    case tooManyOpenFiles
    case unsupportedText
    case changedOnDisk
    case unsavedChanges
    case mixedLineEndings
    case io(String)

    var errorDescription: String? {
        switch self {
        case .unsafePath: return "只能访问当前项目内的普通文件；Git 元数据和越界路径不可编辑。"
        case .symbolicLink: return "为避免写入链接指向的其他位置，编辑器不打开符号链接。"
        case .notRegularFile: return "这不是可编辑的普通文件。"
        case .tooManyOpenFiles: return "每个项目最多打开 100 个编辑标签，请先关闭一些标签。"
        case .tooLarge: return "文件超过 2 MiB，请使用外部编辑器打开。"
        case .unsupportedText: return "只支持 UTF-8 文本；二进制、包含 NUL 或其他编码的文件不能编辑。"
        case .changedOnDisk: return "文件已被其他程序修改，未覆盖磁盘内容。当前编辑草稿仍保留，请先比较两个版本。"
        case .unsavedChanges: return "文件还有未保存的改动。"
        case .mixedLineEndings: return "原文件混用了多种换行符。为避免改变整份文件，请先在外部编辑器统一换行符。当前草稿已保留。"
        case .io(let message): return "文件操作失败：\(message)"
        }
    }
}

/// Edits only explicitly opened regular files beneath one repository root.
/// Disk fingerprints are checked before an atomic replacement; this is not an external-writer CAS lock.
@MainActor
final class EditorWorkspace: ObservableObject {
    let root: URL
    @Published var documents: [EditorDocument] = []
    /// The 编辑 page's columns (向左拆分 / 向右拆分). Each holds some of `documents` as tabs; one file can be in two.
    @Published var columns = PaneColumns()
    /// The document shown in the active column: what ⌘S, sending to the terminal and the other commands work on.
    var selectedDocumentID: String? {
        get { columns.selected }
        set { if columns.selected != newValue { columns.select(newValue) } }
    }
    @Published var errorMessage: String?
    /// Caret and scroll per tab. Deliberately not published: it changes on every caret move and scroll frame, and
    /// publishing it re-rendered the whole window while typing or scrolling. `onSessionChange` reports it instead.
    var tabStates: [String: EditorTabState] = [:]
    /// Called after caret or scroll state changed, so the owner can save the session later.
    var onSessionChange: (() -> Void)?
    /// "发送到终端" in the editor's right-click menu, with the text view's selection.
    var sendSelectionToTerminal: ((NSRange) -> Void)?
    /// 查看调用关系 from the editor's menu: the file, its text and the clicked position.
    var showCallsAt: ((String, String, Int) -> Void)?
    /// "发到终端" in the Markdown reader: the text as read on the page (no Markdown marks), with its line reference.
    var sendTextToTerminal: ((String, String) -> Void)?
    /// 评论 in the Markdown reader: document path, 1-based first and last source line, and the selected text.
    var commentSelection: ((String, Int, Int, String) -> Void)?
    /// 说人话 / 去 AI 腔 on selected text, with where it came from.
    var assistSelection: ((AIAssistState.Mode, String, String) -> Void)?
    /// Headings of each column's Markdown document and the section at its caret, for the outline beside it.
    private var outlines: [UUID: MarkdownOutlineModel] = [:]
    func outline(for column: UUID?) -> MarkdownOutlineModel {
        let id = column ?? columns.activeID
        if let outline = outlines[id] { return outline }
        let outline = MarkdownOutlineModel()
        outlines[id] = outline
        return outline
    }
    var outline: MarkdownOutlineModel { outline(for: nil) }
    /// A short message shown in the editor bar for a few seconds.
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?
    /// The window's 玻璃材质 choice, for the editor's floating controls.
    var glassSurfaces = true

    func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            self?.notice = nil
        }
    }
    @Published var presentation = EditorPresentation()
    /// Markdown files open in the rendered reading view; 编辑 shows the source. Saved with the preferences.
    @Published var markdownReading = true {
        didSet {
            guard oldValue != markdownReading, let id = selectedDocumentID,
                  ["md", "markdown", "mdown"].contains((id as NSString).pathExtension.lowercased()),
                  let document = selectedDocument else { return }
            if markdownReading {
                // The reader opens at the editor's top visible line.
                if let line = editorTopLine?() { readerTopLine[id] = line }
            } else {
                // The editor opens with the reader's top line at its top; a caret far from there moves to it.
                let line = readerTopLine[id] ?? 0
                editorScrollRequest = (id, line)
                let starts = MarkdownReaderView.Coordinator.lineStarts(document.text)
                let caret = tabStates[id]?.selectionLocation ?? 0
                let caretLine = starts.lastIndex { $0 <= caret } ?? 0
                if caretLine < line || caretLine > line + 40 {
                    var state = tabStates[id] ?? EditorTabState(path: document.path)
                    state.selectionLocation = starts[min(line, starts.count - 1)]; state.selectionLength = 0
                    tabStates[id] = state
                }
            }
        }
    }
    /// The source editor's top visible line (0-based), provided by the editor while it is on screen.
    var editorTopLine: (() -> Int?)?
    /// The column the last reveal was for, so only that column's editor scrolls and takes focus.
    var navigationColumn: UUID?
    /// Where the source editor should scroll when it next becomes the visible view: this line at its top.
    var editorScrollRequest: (id: String, line: Int)?
    /// Opens the reading view's find bar; set by the reader while it is on screen.
    var openReaderFind: (() -> Void)?
    /// "查看改动" on the external-change banner: the model shows this file's diff.
    var showChanges: ((String) -> Void)?
    /// When a clean open document was last replaced by a newer version from disk (another program, an agent).
    @Published private(set) var externalChanges: [String: Date] = [:]
    /// The source line at the top of the reading view per document, so 编辑 opens where the reader was.
    var readerTopLine: [String: Int] = [:]
    /// The outline beside Markdown files.
    @Published var showsOutline = true
    /// The outline's width, set by dragging its edge; saved with the preferences.
    @Published var outlineWidth: Double = 220
    var wikiPathCache: (date: Date, paths: [String])?
    @Published private(set) var navigationRevision: UInt64 = 0
    /// Bumped by the model whenever the index may have changed, so open editors reload their gutter base.
    @Published var indexRevision: UInt64 = 0
    /// Reads a file's index version for gutter marks; nil when the file is not tracked as regular text.
    var loadIndexBase: ((String) async -> IndexBase?)?
    /// Writes new index content for one file (the gutter's "暂存这段").
    var stageIndexText: ((IndexBase, Data) -> Void)?
    /// 在光标所在行显示最后修改人; kept in the preferences by the model.
    @Published var showsLineBlame = true
    /// Who last changed each line of a file in HEAD, for the note after the caret's line.
    var loadBlame: (@MainActor (String) async -> LineBlame.Source)?
    /// Commits that changed lines `first...last` (1-based, as HEAD has them) of a file.
    var loadLineHistory: ((String, Int, Int) async -> [FileBlame.Commit])?
    /// Shows a commit in the history view.
    var showCommit: ((String) -> Void)?

    private static let maximumBytes = 2 * 1_024 * 1_024
    private struct Format {
        let hasBOM: Bool
        let newline: String
        let mixedNewlines: Bool
    }
    private struct DiskFile {
        let bytes: Data
        let metadata: stat
    }
    private var formats: [String: Format] = [:]

    init(root: URL) {
        let candidate = root.standardizedFileURL
        // Foundation keeps the /var spelling while its directory enumerator returns /private/var.
        // A POSIX canonical path keeps containment checks consistent for both spellings.
        if let resolved = realpath(candidate.path, nil) {
            self.root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        } else {
            self.root = candidate.resolvingSymlinksInPath()
        }
    }

    var selectedDocument: EditorDocument? {
        documents.first { $0.id == selectedDocumentID }
    }
    var hasUnsavedChanges: Bool { documents.contains { $0.isDirty } }

    /// What the window outside the editor card shows from this workspace.
    struct ChromeSignature: Equatable {
        let ids: [String]
        let dirty: [Bool]
        let selected: String?
        let reading: Bool
        let outline: Bool
        let outlineWidth: Double
    }
    var chromeSignature: ChromeSignature {
        ChromeSignature(ids: documents.map(\.id), dirty: documents.map(\.isDirty), selected: selectedDocumentID,
                        reading: markdownReading, outline: showsOutline, outlineWidth: outlineWidth)
    }

    /// Opens a tab for the file. Pictures and documents open as a preview; so does a file that is not UTF-8 text or is
    /// too big to edit. `asText` opens an SVG's source in place of its preview tab.
    /// `column` puts the tab in that column; otherwise a file already open shows in the column that has it.
    func open(path: String, asText: Bool = false, in column: UUID? = nil) throws {
        let components = try safeComponents(path)
        let normalizedPath = components.joined(separator: "/")
        func show() {
            if let column, columns.index(of: column) != nil { columns.select(normalizedPath, in: column) }
            else { selectedDocumentID = normalizedPath }
        }
        if let index = documents.firstIndex(where: { $0.id == normalizedPath }) {
            guard asText, documents[index].preview != nil else { show(); return }
            let text = try readText(normalizedPath)
            documents[index] = EditorDocument(id: normalizedPath, path: normalizedPath, text: text.text, originalText: text.text,
                                              fingerprint: text.fingerprint)
            formats[normalizedPath] = text.format
            show()
            return
        }
        guard documents.count < 100 else { throw FileEditorError.tooManyOpenFiles }
        if !asText, let kind = FilePreviewKind(path: normalizedPath) { try openPreview(normalizedPath, kind: kind); show(); return }
        let opened: (text: String, format: Format, fingerprint: String)
        do { opened = try readText(normalizedPath) }
        catch FileEditorError.unsupportedText where !asText { try openPreview(normalizedPath, kind: .file); show(); return }
        catch FileEditorError.tooLarge where !asText {
            try openPreview(normalizedPath, kind: .document)
            show()
            showNotice("文件超过 2 MiB，只能预览")
            return
        }
        documents.append(EditorDocument(id: normalizedPath, path: normalizedPath,
                                        text: opened.text, originalText: opened.text,
                                        fingerprint: opened.fingerprint))
        formats[normalizedPath] = opened.format
        tabStates[normalizedPath] = EditorTabState(path: normalizedPath)
        show()
    }

    private func readText(_ path: String) throws -> (text: String, format: Format, fingerprint: String) {
        let disk = try withFile(path: path) { fd, _ in try read(fd: fd) }
        let (text, format) = try Self.decode(disk.bytes)
        return (text, format, fingerprint(disk.bytes))
    }

    private func openPreview(_ path: String, kind: FilePreviewKind) throws {
        let stamp = try withFile(path: path) { fd, _ in try previewStamp(fd: fd) }
        documents.append(EditorDocument(id: path, path: path, text: "", originalText: "", fingerprint: stamp, preview: kind))
        tabStates[path] = EditorTabState(path: path)
    }

    /// A preview tab is not read into memory; its size and modification time tell when the file changed.
    private func previewStamp(fd: Int32) throws -> String {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw systemError() }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw FileEditorError.notRegularFile }
        return "\(metadata.st_size)-\(metadata.st_mtimespec.tv_sec).\(metadata.st_mtimespec.tv_nsec)"
    }

    /// Re-reads open documents that have no unsaved edits and takes the disk version when it differs. Documents with
    /// edits are left alone; saving them still refuses to overwrite a newer disk file. Returns the replaced ids.
    @discardableResult
    func reloadCleanDocuments() -> [String] {
        var replaced: [String] = []
        for index in documents.indices where !documents[index].isDirty {
            let id = documents[index].id
            if documents[index].preview != nil {
                guard let stamp = try? withFile(path: id, { fd, _ in try previewStamp(fd: fd) }),
                      stamp != documents[index].fingerprint else { continue }
                documents[index].fingerprint = stamp
                externalChanges[id] = Date()
                replaced.append(id)
                continue
            }
            guard let disk = try? withFile(path: id, { fd, _ in try read(fd: fd) }),
                  fingerprint(disk.bytes) != documents[index].fingerprint,
                  let (text, format) = try? Self.decode(disk.bytes) else { continue }
            documents[index].text = text
            documents[index].originalText = text
            documents[index].fingerprint = fingerprint(disk.bytes)
            formats[id] = format
            externalChanges[id] = Date()
            replaced.append(id)
        }
        return replaced
    }
    func dismissExternalChange(_ id: String) { externalChanges[id] = nil }

    /// Flips the task box whose mark sits at `offset` (` ` ↔ `x`). A document without other edits is saved right away,
    /// so ticking a box in the reading view behaves like a checklist; otherwise it joins the unsaved edits.
    func toggleTask(at offset: Int, in documentID: String) throws {
        guard let document = documents.first(where: { $0.id == documentID }) else { return }
        let source = document.text as NSString
        guard offset > 0, offset + 1 < source.length,
              source.substring(with: NSRange(location: offset - 1, length: 1)) == "[",
              source.substring(with: NSRange(location: offset + 1, length: 1)) == "]" else { return }
        let mark = source.substring(with: NSRange(location: offset, length: 1))
        guard [" ", "x", "X"].contains(mark) else { return }
        let wasClean = !document.isDirty
        updateText(id: documentID, text: source.replacingCharacters(in: NSRange(location: offset, length: 1), with: mark == " " ? "x" : " "))
        if wasClean, selectedDocumentID == documentID { try saveSelected() }
    }

    /// Leaves the reading view for the source, with the caret at the start of `line` (0-based).
    /// 编辑这里: switch to the source with the caret at `line`, or with `selecting` selected when the reader found the
    /// exact words that were selected.
    func editMarkdown(at line: Int?, in documentID: String, selecting: NSRange? = nil) {
        if let document = documents.first(where: { $0.id == documentID }), line != nil || selecting != nil {
            var state = tabStates[documentID] ?? EditorTabState(path: document.path)
            if let selecting {
                let range = EditorTextPosition.clamp(selecting, in: document.text)
                state.selectionLocation = range.location; state.selectionLength = range.length
            } else if let line {
                let starts = MarkdownReaderView.Coordinator.lineStarts(document.text)
                state.selectionLocation = starts[max(0, min(line, starts.count - 1))]; state.selectionLength = 0
            }
            tabStates[documentID] = state
        }
        markdownReading = false
    }

    /// Only paths and caret/scroll state are persisted. Unsaved text stays in this in-memory workspace.
    func sessionState() -> [EditorTabState] {
        documents.prefix(100).map { document in
            var state = tabStates[document.id] ?? EditorTabState(path: document.path)
            let range = EditorTextPosition.clamp(NSRange(location: state.selectionLocation, length: state.selectionLength), in: document.text)
            state.selectionLocation = range.location; state.selectionLength = range.length
            state.scrollOffset = state.scrollOffset.isFinite ? max(0, state.scrollOffset) : 0
            return state
        }
    }

    func restoreSession(tabs: [EditorTabState], selectedPath: String?, columns saved: PaneColumns? = nil) {
        var failures = [String]()
        for state in tabs.prefix(100) {
            do {
                try open(path: state.path)
                guard let document = documents.first(where: { $0.id == state.path }) else { continue }
                let selection = EditorTextPosition.clamp(NSRange(location: max(0, state.selectionLocation), length: max(0, state.selectionLength)), in: document.text)
                tabStates[state.path] = EditorTabState(path: state.path, selectionLocation: selection.location,
                    selectionLength: selection.length, scrollOffset: state.scrollOffset.isFinite ? max(0, state.scrollOffset) : 0)
            } catch { failures.append("\(state.path)：\(error.localizedDescription)") }
        }
        if let saved {
            columns = saved
            columns.keep(documents.map(\.id))
        } else if let selectedPath, documents.contains(where: { $0.id == selectedPath }) { selectedDocumentID = selectedPath }
        else { selectedDocumentID = documents.first?.id }
        if !failures.isEmpty { errorMessage = "部分编辑标签无法恢复，其余标签已保留。\n" + failures.joined(separator: "\n") }
    }

    func reveal(path: String, range: NSRange? = nil, line: Int? = nil, column: Int? = nil) throws {
        try open(path: path)
        guard let document = selectedDocument else { return }
        let position: NSRange
        if let range { position = EditorTextPosition.clamp(range, in: document.text) }
        else if let line { position = EditorTextPosition.range(line: line, column: column ?? 1, in: document.text) }
        else { position = EditorTextPosition.clamp(NSRange(location: tabStates[document.id]?.selectionLocation ?? 0, length: 0), in: document.text) }
        var state = tabStates[document.id] ?? EditorTabState(path: document.path)
        state.selectionLocation = position.location; state.selectionLength = position.length
        tabStates[document.id] = state
        navigationColumn = columns.activeID
        navigationRevision &+= 1
    }

    /// Files a ⌘-clicked link hands to their default app; the ones with a preview tab open here instead.
    static let externalExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "svg",
                                                  "pdf", "mp4", "mov", "mp3", "wav", "zip"]

    /// ⌘-click on a Markdown link in `documentPath`: web addresses go to the browser, project files open here at their
    /// line or heading, images and PDFs in a preview tab. Anything outside the project is refused.
    func followLink(_ target: String, from documentPath: String) {
        switch MarkdownLinks.resolve(target, from: documentPath) {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .anchor(let anchor):
            guard let document = documents.first(where: { $0.id == documentPath }),
                  let line = MarkdownLinks.headingLine(anchor, in: document.text) else { errorMessage = "找不到标题「\(anchor)」。"; return }
            try? reveal(path: documentPath, line: line)
        case let .file(path, line, anchor):
            let url = root.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                errorMessage = "找不到链接的文件：\(path)"; return
            }
            // Only an existing path resolves its symlinks, so this check comes after the existence check.
            let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard (url.resolvingSymlinksInPath().standardizedFileURL.path + "/").hasPrefix(base) else {
                errorMessage = "链接指向项目之外，没有打开：\(target)"; return
            }
            if isDirectory.boolValue { NSWorkspace.shared.activateFileViewerSelecting([url]); return }
            if Self.externalExtensions.contains(url.pathExtension.lowercased()), FilePreviewKind(path: path) == nil {
                NSWorkspace.shared.open(url); return
            }
            do {
                try reveal(path: path, line: line)
                if let anchor, let document = selectedDocument, let headingLine = MarkdownLinks.headingLine(anchor, in: document.text) {
                    try reveal(path: path, line: headingLine)
                }
            } catch { errorMessage = "打开链接失败：\(error.localizedDescription)" }
        case let .wiki(name, anchor):
            followWikiLink(name, anchor: anchor, from: documentPath) { name in
                let alert = NSAlert()
                alert.messageText = "还没有笔记「\(name)」"
                alert.informativeText = "在当前文件所在的文件夹新建 \(name).md 并打开？"
                alert.addButton(withTitle: "新建"); alert.addButton(withTitle: "取消")
                return alert.runModal() == .alertFirstButtonReturn
            }
        case .refused(let reason):
            errorMessage = reason + "：" + target
        }
    }

    func updateEditorState(id: String, selection: NSRange, scrollOffset: Double) {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        let range = EditorTextPosition.clamp(selection, in: document.text)
        let state = EditorTabState(path: document.path, selectionLocation: range.location, selectionLength: range.length,
                                   scrollOffset: scrollOffset.isFinite ? max(0, scrollOffset) : 0)
        if tabStates[id] != state { tabStates[id] = state; onSessionChange?() }
    }

    func updateText(id: String, text: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].preview == nil,
              documents[index].text != text else { return }
        documents[index].text = text
    }

    func saveSelected() throws {
        guard let id = selectedDocumentID else { return }
        try save(id: id)
    }

    func saveAll() throws {
        // Stop on the first conflict; already-saved files remain saved and all other drafts remain intact.
        for id in documents.filter({ $0.isDirty }).map(\.id) { try save(id: id) }
    }

    func close(id: String, discard: Bool = false) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        guard discard || !documents[index].isDirty else { throw FileEditorError.unsavedChanges }
        documents.remove(at: index)
        formats.removeValue(forKey: id)
        tabStates.removeValue(forKey: id)
        columns.remove(id)
    }

    /// Closes the tab in one column. A file still open in another column stays open there, so nothing is asked.
    func closeTab(id: String, in column: UUID?, discard: Bool = false) throws {
        if let column, columns.columns.contains(where: { $0.id != column && $0.tabs.contains(id) }) {
            columns.remove(id, from: column)
        } else { try close(id: id, discard: discard) }
    }
    /// Whether closing the tab in this column closes the file (and so may lose unsaved edits).
    func closingClosesFile(_ id: String, in column: UUID?) -> Bool {
        guard let column else { return true }
        return !columns.columns.contains { $0.id != column && $0.tabs.contains(id) }
    }

    enum TabCloseScope: CaseIterable { case others, left, right, saved, all }
    /// Closes a group of tabs around `id`. Tabs with unsaved edits stay open (nothing is lost without asking);
    /// returns how many were kept.
    /// Only the tabs of the column holding `id` count (the active column when given none).
    @discardableResult
    func closeTabs(_ scope: TabCloseScope, around id: String, in column: UUID? = nil) -> Int {
        guard let position = column.flatMap(columns.index(of:)) ?? columns.column(containing: id) else { return 0 }
        let columnID = columns.columns[position].id
        let tabs = columns.columns[position].tabs
        guard let index = tabs.firstIndex(of: id) else { return 0 }
        let ids: [String]
        switch scope {
        case .others: ids = tabs.filter { $0 != id }
        case .left: ids = Array(tabs[..<index])
        case .right: ids = Array(tabs[(index + 1)...])
        case .saved: ids = tabs.filter { tab in documents.first { $0.id == tab }?.isDirty != true }
        case .all: ids = tabs
        }
        let targets = ids.compactMap { tab in documents.first { $0.id == tab } }
        let selectedClosed = columns.columns[position].selected.map(ids.contains) ?? false
        var kept = 0
        for document in targets {
            if !closingClosesFile(document.id, in: columnID) { columns.remove(document.id, from: columnID) }
            else if document.isDirty { kept += 1 }
            else { try? close(id: document.id) }
        }
        if selectedClosed, scope != .all, columns.index(of: columnID) != nil, documents.contains(where: { $0.id == id }) {
            columns.select(id, in: columnID)
        }
        if kept > 0 { showNotice("\(kept) 个未保存的标签保留了") }
        return kept
    }

    func filePaths() throws -> [String] {
        _ = try safeComponents("__file_browser_guard__")
        let ignored = Set([".git", ".build", "build", "node_modules", "vendor", "dist"])
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw FileEditorError.io("无法读取项目文件列表") }
        var paths: [String] = []
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > 20_000 || paths.count >= 5_000 { break }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true || ignored.contains(url.lastPathComponent.lowercased()) {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard url.path.hasPrefix(prefix) else { continue }
            let relative = String(url.path.dropFirst(prefix.count))
            // Enumeration does not read the file. Open and save repeat anchored path checks.
            _ = try safeComponents(relative)
            paths.append(relative)
        }
        if let error = enumerationError { throw FileEditorError.io(error.localizedDescription) }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func save(id: String) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].isDirty else { return }
        let document = documents[index]
        guard let format = formats[id] else { throw FileEditorError.unsupportedText }
        guard !format.mixedNewlines else { throw FileEditorError.mixedLineEndings }
        guard !document.text.contains("\0") else { throw FileEditorError.unsupportedText }
        var data = Data(document.text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: format.newline).utf8)
        if format.hasBOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        guard data.count <= Self.maximumBytes else { throw FileEditorError.tooLarge }
        try withFile(path: id) { fd, parentFD in
            let before = try read(fd: fd)
            guard fingerprint(before.bytes) == document.fingerprint else { throw FileEditorError.changedOnDisk }
            let filename = try safeComponents(id).last!
            let temporaryName = ".folmi-save-\(UUID().uuidString)"
            let temporaryFD = openat(parentFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard temporaryFD >= 0 else { throw systemError() }
            defer {
                Darwin.close(temporaryFD)
                unlinkat(parentFD, temporaryName, 0)
            }
            try write(data, fd: temporaryFD)
            guard fchmod(temporaryFD, before.metadata.st_mode & mode_t(0o7777)) == 0 else { throw systemError() }
            guard fsync(temporaryFD) == 0 else { throw systemError() }
            // Check both the opened inode and the current directory entry before replacing it.
            let latest = try read(fd: fd)
            let currentFD = openat(parentFD, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard currentFD >= 0 else {
                if errno == ELOOP { throw FileEditorError.symbolicLink }
                throw FileEditorError.changedOnDisk
            }
            defer { Darwin.close(currentFD) }
            let current = try read(fd: currentFD)
            guard latest.metadata.st_dev == before.metadata.st_dev,
                  latest.metadata.st_ino == before.metadata.st_ino,
                  current.metadata.st_dev == before.metadata.st_dev,
                  current.metadata.st_ino == before.metadata.st_ino,
                  fingerprint(latest.bytes) == document.fingerprint,
                  fingerprint(current.bytes) == document.fingerprint else { throw FileEditorError.changedOnDisk }
            guard renameat(parentFD, temporaryName, parentFD, filename) == 0 else { throw systemError() }
        }
        documents[index].originalText = documents[index].text
        documents[index].fingerprint = fingerprint(data)
    }

    private func safeComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !root.pathComponents.contains(where: { $0.lowercased() == ".git" }) else { throw FileEditorError.unsafePath }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw FileEditorError.unsafePath
        }
        return components
    }

    private func withFile<T>(path: String, _ operation: (Int32, Int32) throws -> T) throws -> T {
        let components = try safeComponents(path)
        var directoryFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw systemError() }
        defer { Darwin.close(directoryFD) }
        for directory in components.dropLast() {
            let next = openat(directoryFD, directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                if errno == ELOOP || errno == ENOTDIR { throw FileEditorError.symbolicLink }
                throw systemError()
            }
            Darwin.close(directoryFD)
            directoryFD = next
        }
        let fd = openat(directoryFD, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw FileEditorError.symbolicLink }
            throw systemError()
        }
        defer { Darwin.close(fd) }
        return try operation(fd, directoryFD)
    }

    private func read(fd: Int32) throws -> DiskFile {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw systemError() }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw FileEditorError.notRegularFile }
        guard metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes else { throw FileEditorError.tooLarge }
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw systemError() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError()
            }
            if count == 0 { break }
            guard data.count + count <= Self.maximumBytes else { throw FileEditorError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        return DiskFile(bytes: data, metadata: metadata)
    }

    private func write(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError()
                }
                guard count > 0 else { throw FileEditorError.io("无法完成文件写入") }
                offset += count
            }
        }
    }

    /// File bytes as the editor holds them (BOM dropped, line endings normalized), the same text the reader renders.
    nonisolated static func readerText(_ data: Data) -> String? { try? decode(data).0 }
    nonisolated static func isMarkdownPath(_ path: String) -> Bool { ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased()) }
    nonisolated private static func decode(_ data: Data) throws -> (String, Format) {
        let hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        let content = hasBOM ? Data(data.dropFirst(3)) : data
        guard !content.contains(0), let text = UTF8Text.decode(content) else { throw FileEditorError.unsupportedText }
        let crlf = text.components(separatedBy: "\r\n").count - 1
        let withoutCRLF = text.replacingOccurrences(of: "\r\n", with: "")
        let lf = withoutCRLF.contains("\n")
        let cr = withoutCRLF.contains("\r")
        let styles = (crlf > 0 ? 1 : 0) + (lf ? 1 : 0) + (cr ? 1 : 0)
        let newline = crlf > 0 ? "\r\n" : (cr ? "\r" : "\n")
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return (normalized, Format(hasBOM: hasBOM, newline: newline, mixedNewlines: styles > 1))
    }

    private func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func systemError() -> FileEditorError {
        .io(String(cString: strerror(errno)))
    }
}
