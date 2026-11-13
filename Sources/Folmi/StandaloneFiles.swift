import AppKit
import Observation
import SwiftUI

/// A file window has its own editor and no repository. Reopening a file brings its existing draft to the front.
@MainActor
@Observable
final class StandaloneFiles {
    @ObservationIgnored private var windows: [URL: StandaloneFileWindow] = [:]
    @ObservationIgnored private var folders: [URL: NSWindow] = [:]
    private(set) var active: StandaloneFileWindow?

    func choose(using model: FolmiModel) {
        let panel = NSOpenPanel()
        panel.title = "打开文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url, using: model) }
    }

    func open(_ url: URL, using model: FolmiModel) {
        do { try show(url, using: model) }
        catch {
            let alert = NSAlert()
            alert.messageText = "无法打开文件「\(url.lastPathComponent)」"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @discardableResult
    func show(_ url: URL, using model: FolmiModel) throws -> StandaloneFileWindow {
        let workspace = EditorWorkspace(root: url.deletingLastPathComponent(), markdownReading: model.preferences.markdownReading,
                                        singleFilePath: url.lastPathComponent)
        // Use the canonical parent but keep the final component so the editor still rejects symbolic links.
        let file = workspace.root.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        if let existing = windows[file] {
            existing.showWindow(nil)
            return existing
        }
        try workspace.open(path: file.lastPathComponent)
        workspace.presentation = model.editorPresentation
        workspace.glassSurfaces = model.glassSurfaces
        workspace.showsOutline = model.preferences.markdownOutline
        workspace.outlineWidth = model.preferences.markdownOutlineWidth
        let controller = StandaloneFileWindow(file: file, workspace: workspace, model: model)
        controller.onFocus = { [weak self, weak controller] focused in
            guard let self, let controller else { return }
            if focused { self.active = controller }
            else if self.active === controller { self.active = nil }
        }
        controller.onClose = { [weak self] in self?.windows[file] = nil }
        windows[file] = controller
        controller.showWindow(nil)
        return controller
    }

    func prepareToQuit() -> Bool {
        windows.values.allSatisfy { $0.confirmClosing(quitting: true) }
    }

    func openFolder(_ folder: URL, using model: FolmiModel) {
        if let window = folders[folder] {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.title = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
            window.representedURL = folder
            window.contentView = NSHostingView(rootView: StandaloneFolderView(folder: folder, model: model)
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { [weak self, weak window] notice in
                    guard let window, notice.object as? NSWindow === window else { return }
                    self?.folders[folder] = nil
                })
            window.center()
            folders[folder] = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct StandaloneFolderView: View {
    let folder: URL
    let model: FolmiModel
    @StateObject private var expansion = ProjectTreeExpansion()
    @State private var tree: ProjectTreeSnapshot?
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("筛选文件和文件夹", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            if let tree {
                ProjectFileTreeView(nodes: tree.roots, query: query, selectedPath: nil, changedPaths: [], busy: false,
                                    onOpen: { model.standaloneFiles.open(folder.appendingPathComponent($0), using: model) },
                                    root: folder, onLoadFolder: loadFolder, expansion: expansion)
                if let notice = tree.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).padding(8)
                }
            } else if let error {
                ContentUnavailableView("无法打开文件夹", systemImage: "folder", description: Text(error))
            } else {
                ProgressView("读取文件夹…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 360, minHeight: 260)
        .background(Color.theme(model.theme, \.canvas))
        .background(WindowChrome(color: model.theme.palette.canvas))
        .preferredColorScheme(model.colorScheme)
        .environment(\.folmiTheme, model.theme)
        .task {
            let folder = self.folder
            do { tree = try await Task.detached(priority: .utility) { try ProjectFileTree.scan(root: folder) }.value }
            catch { self.error = error.localizedDescription }
        }
    }

    private func loadFolder(_ path: String) {
        Task {
            let folder = self.folder
            let loaded: ProjectTreeSnapshot
            do {
                loaded = try await Task.detached(priority: .utility) {
                    try ProjectFileTree.loadFolder(root: folder, path: path)
                }.value
            } catch {
                loaded = ProjectTreeSnapshot(roots: [], fileCount: 0, isTruncated: false, notice: error.localizedDescription)
            }
            if let tree {
                self.tree = ProjectTreeSnapshot(roots: ProjectFileTree.replacingChildren(in: tree.roots, path: path, with: loaded),
                                                fileCount: tree.fileCount + loaded.fileCount,
                                                isTruncated: tree.isTruncated || loaded.isTruncated, notice: tree.notice)
            }
        }
    }
}

@MainActor
final class StandaloneFileWindow: NSWindowController, NSWindowDelegate {
    let workspace: EditorWorkspace
    var onFocus: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    init(file: URL, workspace: EditorWorkspace, model: FolmiModel) {
        self.workspace = workspace
        let window = FileWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = file.lastPathComponent
        window.representedURL = file
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.contentView = NSHostingView(rootView: StandaloneFileView(workspace: workspace, model: model,
                                                                      onEdited: { [weak window] in window?.isDocumentEdited = $0 }))
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onSave = { [weak self] in self?.save() }
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        workspace.reloadCleanDocuments()
        onFocus?(true)
    }
    func windowDidResignKey(_ notification: Notification) { onFocus?(false) }
    func windowWillClose(_ notification: Notification) { onFocus?(false); onClose?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClosing() }

    func confirmClosing(quitting: Bool = false) -> Bool {
        guard workspace.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "要保存「\(window?.title ?? "")」的改动吗？"
        alert.informativeText = "放弃后，未保存的改动将丢失。"
        alert.addButton(withTitle: quitting ? "保存并退出" : "保存并关闭")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "放弃改动")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save()
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    @discardableResult
    func save() -> Bool {
        do { try workspace.saveSelected(); return true }
        catch {
            window?.makeKeyAndOrderFront(nil)
            workspace.errorMessage = error.localizedDescription
            return false
        }
    }

    var isMarkdown: Bool { workspace.selectedDocumentID.map(EditorWorkspace.isMarkdownPath) == true }
}

private final class FileWindow: NSWindow {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if (modifiers == .command || modifiers == [.command, .shift]), event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct StandaloneFileView: View {
    @ObservedObject var workspace: EditorWorkspace
    let model: FolmiModel
    let onEdited: (Bool) -> Void

    var body: some View {
        FileEditorPane(workspace: workspace, onSave: {})
            .buttonStyle(ThemedDefaultButtonStyle())
            .tint(Color.theme(model.theme, \.accent))
            .preferredColorScheme(model.colorScheme)
            .background(WindowChrome(color: model.theme.palette.canvas))
            .themedFont(.body, points: 13)
            .environment(\.folmiTheme, model.theme)
            .environment(\.folmiGlass, model.glassSurfaces)
            .fontDesign(model.theme.style.pixelFont && PixelFont.isAvailable ? nil : model.theme.style.fontDesign)
            .onChange(of: workspace.hasUnsavedChanges) { _, edited in onEdited(edited) }
            .onChange(of: model.editorPresentation) { _, presentation in workspace.presentation = presentation }
            .onChange(of: model.glassSurfaces) { _, glass in workspace.glassSurfaces = glass }
    }
}
