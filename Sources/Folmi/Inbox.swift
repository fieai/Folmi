import AppKit
import Carbon.HIToolbox
import FolmiCore
import SwiftUI

/// A global shortcut as Carbon takes it, plus the key's name for menus and settings.
struct IdeaHotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let standard = IdeaHotKey(keyCode: UInt32(kVK_F11), modifiers: UInt32(controlKey | optionKey), key: "F11")

    var title: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    fileprivate static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]
}

extension IdeaHotKey {
    /// The shortcut a key press in the recorder stands for. Nil for a lone modifier, or for a key without ⌃ ⌥ or ⌘
    /// (it would stop typing that key everywhere); function keys may go alone.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let code = Int(keyCode)
        let name: String
        if let function = Self.functionKeys[code] {
            name = function
        } else {
            guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
            if code == kVK_Space { name = "Space" }
            else if let first = characters?.uppercased().first, !first.isWhitespace, !first.isNewline,
                    first.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0xF700 }) { name = String(first) }
            else { return nil }
        }
        self.init(keyCode: UInt32(code), modifiers: modifiers, key: name)
    }
}

/// Notes taken with the shortcut: one Markdown file each in the project's ideas/ folder, ordinary files Git sees like
/// any other. "只留在本机" is the folder's line in .git/info/exclude, so that state lives in Git, not in Folmi.
enum IdeaStore {
    static let folder = "ideas"
    static let excludeLine = "/ideas/"
    private static let excludeNote = "# Folmi 随手记：只留在本机"

    static func newFile(in root: URL, at date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = formatter.string(from: date)
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        var url = directory.appendingPathComponent(base + ".md"), number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(number).md"); number += 1
        }
        return url
    }

    /// Writes the note; a note left empty leaves no file behind.
    static func save(_ text: String, to url: URL) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The repository's info/exclude, which its worktrees share; nil outside Git.
    static func excludeFile(for root: URL) -> URL? {
        guard let gitDir = AIEventStore.locate(from: root)?.gitDir else { return nil }
        var common = gitDir
        if let raw = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            common = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : gitDir.appendingPathComponent(path)).standardized
        }
        return common.appendingPathComponent("info", isDirectory: true).appendingPathComponent("exclude")
    }

    static func isLocalOnly(_ root: URL) -> Bool {
        guard let url = excludeFile(for: root), let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == excludeLine }
    }

    static func setLocalOnly(_ localOnly: Bool, root: URL) throws {
        guard let url = excludeFile(for: root) else { throw FolmiFailure(message: "这个文件夹不是 Git 仓库。") }
        guard localOnly != isLocalOnly(root) else { return }
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if localOnly {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += "\(excludeNote)\n\(excludeLine)\n"
        } else {
            text = text.components(separatedBy: "\n")
                .filter { ![excludeNote, excludeLine].contains($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: "\n")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The note open in the panel. Every edit is written a moment later, and at once when the panel goes away.
@MainActor @Observable
final class IdeaDraft {
    struct Project: Identifiable, Equatable { let root: URL; let name: String; var id: String { root.path } }
    let projects: [Project]
    private(set) var root: URL
    private(set) var url: URL
    var text: String { didSet { if text != oldValue { scheduleSave() } } }
    private(set) var localOnly: Bool
    var errorMessage: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var saved: String

    init(projects: [Project], root: URL, resume: URL?) {
        self.projects = projects; self.root = root
        if let resume, let existing = try? String(contentsOf: resume, encoding: .utf8) {
            url = resume; text = existing; saved = existing
        } else {
            url = IdeaStore.newFile(in: root); text = ""; saved = ""
        }
        localOnly = IdeaStore.isLocalOnly(root)
    }

    var projectName: String { projects.first { $0.root == root }?.name ?? root.lastPathComponent }
    var relativePath: String { "\(IdeaStore.folder)/\(url.lastPathComponent)" }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func scheduleSave() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        pending?.cancel(); pending = nil
        guard text != saved else { return }
        do { try IdeaStore.save(text, to: url); saved = text; errorMessage = nil }
        catch { errorMessage = "没保存上：\(error.localizedDescription)" }
    }

    /// Moves the note to another project: the file written so far goes with it.
    func move(to project: Project) {
        guard project.root != root else { return }
        pending?.cancel(); pending = nil
        let old = url
        root = project.root; url = IdeaStore.newFile(in: project.root); localOnly = IdeaStore.isLocalOnly(project.root)
        saved = ""
        saveNow()
        if errorMessage == nil, FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.removeItem(at: old) }
    }

    func setLocalOnly(_ value: Bool) {
        do { try IdeaStore.setLocalOnly(value, root: root); localOnly = IdeaStore.isLocalOnly(root); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}

/// The shortcut from anywhere opens a small Markdown editor over every app; it writes as you type and goes away with
/// Esc, the shortcut again, or a click elsewhere. Uses a Carbon hot key, which needs no accessibility permission, and a
/// non-activating panel, so the app you were in stays in front and gets the keyboard back.
@MainActor
final class InboxPanel {
    static let shared = InboxPanel()
    /// The shortcut within this long of the last note goes back to it instead of starting a new one.
    static let resumeWindow: TimeInterval = 5 * 60
    private(set) var panel: NSPanel?
    private(set) var draft: IdeaDraft?
    private var hotKey: EventHotKeyRef?
    private var handlerInstalled = false
    private var resignObserver: NSObjectProtocol?
    private weak var model: FolmiModel?
    /// Each project's last note and when it was put away.
    private var recent: [String: (url: URL, at: Date)] = [:]

    func register(model: FolmiModel) {
        self.model = model
        if !install(model.ideaHotKey) { model.record("随手记快捷键没设上", "\(model.ideaHotKey.title) 已被别的 App 占用，可以在设置里换一个。", isError: true) }
    }

    /// Takes the shortcut, giving up the previous one; false when another app already holds it.
    @discardableResult
    func install(_ key: IdeaHotKey) -> Bool {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { InboxPanel.shared.toggle() } }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let id = EventHotKeyID(signature: OSType(0x5742_4958), id: 1) // "WBIX"
        var ref: EventHotKeyRef?
        guard RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return false }
        hotKey = ref
        return true
    }

    /// Lets go of the shortcut while the settings recorder listens for a new one.
    func suspend() { if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil } }

    func toggle() { if panel?.isVisible == true { hide() } else { show(model: nil) } }

    func show(model: FolmiModel?) {
        if let model { self.model = model }
        guard let model = self.model else { return }
        if let panel, panel.isVisible { panel.makeKeyAndOrderFront(nil); return }
        let projects = model.projects.filter { !$0.isDemo || FileManager.default.fileExists(atPath: $0.rootPath) }
            .map { IdeaDraft.Project(root: URL(fileURLWithPath: $0.rootPath), name: $0.name) }
        guard let root = model.repositoryURL ?? projects.first?.root else { NSSound.beep(); return }
        let last = recent[root.path]
        let resume = last.flatMap { Date().timeIntervalSince($0.at) < Self.resumeWindow && FileManager.default.fileExists(atPath: $0.url.path) ? $0.url : nil }
        let draft = IdeaDraft(projects: projects.contains { $0.root == root } ? projects : [IdeaDraft.Project(root: root, name: root.lastPathComponent)] + projects,
                              root: root, resume: resume)
        self.draft = draft

        let panel = self.panel ?? makePanel()
        // The window's own look: theme colors, glass, light or dark, and the editor's font and colors.
        let view = IdeaEditorView(draft: draft, presentation: model.editorPresentation, theme: model.theme, glass: model.glassSurfaces,
                                  onClose: { [weak self] in self?.hide() }, onOpen: { [weak self] in self?.openInFolmi() })
            .buttonStyle(ThemedDefaultButtonStyle())
            .tint(Color.theme(model.theme, \.accent))
            .preferredColorScheme(model.colorScheme)
            .background { WindowBackdrop(theme: model.theme, glass: model.glassSurfaces) }
        panel.contentView = NSHostingView(rootView: view)
        if self.panel == nil { panel.center(); panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY + 120)) }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        // The editor takes the caret itself once it is in the window. Should the panel still not be key (another app
        // kept the keyboard), Folmi steps in front for it.
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// The note in the main window, where it reads like any other Markdown file.
    func openInFolmi() {
        guard let draft, let model else { return }
        draft.saveNow()
        let root = draft.root, path = draft.relativePath, exists = FileManager.default.fileExists(atPath: draft.url.path)
        hide()
        guard exists else { return }
        NSApp.activate(ignoringOtherApps: true)
        let target = root.resolvingSymlinksInPath().path
        if model.repositoryURL?.resolvingSymlinksInPath().path != target {
            if let project = model.projects.first(where: { URL(fileURLWithPath: $0.rootPath).resolvingSymlinksInPath().path == target }) {
                model.switchProject(project.rootPath)
            } else { model.open(root) }
        }
        Task { @MainActor [weak model] in
            // The project may still be loading; the note opens once it is in front.
            for _ in 0..<150 {
                guard let model else { return }
                if !model.busy, model.repositoryURL?.resolvingSymlinksInPath().path == target, model.snapshot != nil {
                    model.editPath(path); return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        guard let draft else { return }
        draft.saveNow()
        if let error = draft.errorMessage { model?.record("随手记没保存上", "\(draft.url.path)\n\(error)", isError: true) }
        else if !draft.isEmpty {
            recent[draft.root.path] = (draft.url, Date())
            model?.record("随手记", "\(draft.url.path)\n\(draft.text.prefix(200))")
        }
        self.draft = nil
        panel.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = IdeaWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                               styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 380, height: 200)
        panel.setFrameAutosaveName("FolmiIdeaPanel")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.onClose = { [weak self] in self?.hide() }
        // A click in another app puts the note away, like the shortcut.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { InboxPanel.shared.hide() }
        }
        return panel
    }
}

private final class IdeaWindow: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func performClose(_ sender: Any?) { onClose?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }
}

private struct IdeaEditorView: View {
    @Bindable var draft: IdeaDraft
    let presentation: EditorPresentation
    let theme: FolmiTheme
    let glass: Bool
    let onClose: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(ThemeColor(token: .accent))
                Menu(draft.projectName) {
                    ForEach(draft.projects) { project in
                        Button(project.name) { draft.move(to: project) }.disabled(project.root == draft.root)
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().help("记到哪个项目；切换时这条会跟着搬过去")
                Text(draft.relativePath).themedFont(.caption, points: 11).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Toggle("只留在本机", isOn: Binding(get: { draft.localOnly }, set: { draft.setLocalOnly($0) }))
                    .toggleStyle(.checkbox).themedFont(.caption, points: 11)
                    .help("把 ideas/ 写进这个仓库的 .git/info/exclude：Git 不再看到这些文件，不会提交，也不改团队共享的 .gitignore。已经提交过的想法不受影响。")
            }
            .padding(.leading, 14).padding(.trailing, 12).padding(.top, 10).padding(.bottom, 6)
            Divider()
            IdeaTextView(text: $draft.text, presentation: presentation, theme: theme, glass: glass, onClose: onClose)
            HStack {
                if let error = draft.errorMessage { Text(error).foregroundStyle(.red).lineLimit(1) }
                else { Text("边写边保存 · Esc 收起").foregroundStyle(.secondary) }
                Spacer()
                Button("在 Folmi 里打开", action: onOpen).buttonStyle(.themedLink).disabled(draft.isEmpty)
                    .help("收起这里，在主窗口打开这条想法：可以用阅读模式看，也可以交给终端里的 AI")
            }
            .themedFont(.caption2, points: 10).padding(.horizontal, 14).padding(.vertical, 6)
        }
        .frame(minWidth: 380, minHeight: 200)
    }
}

/// Takes the caret as soon as it is in the panel, at the end of the note.
private final class IdeaEditorTextView: EditorTextView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(self)
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }
}

/// Folmi's Markdown editor (list continuation, indent, format bar, highlighting) in the editor's font and theme colors,
/// without a project document behind it.
private struct IdeaTextView: NSViewRepresentable {
    @Binding var text: String
    let presentation: EditorPresentation
    let theme: FolmiTheme
    let glass: Bool
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let editor = IdeaEditorTextView(frame: .zero)
        editor.setAccessibilityIdentifier("idea-editor")
        editor.markdownEditing = true
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.overlays.style = { [theme, glass] in (theme, glass) }
        editor.string = text; editor.delegate = context.coordinator
        scroll.documentView = editor
        context.coordinator.highlighter.editor = editor
        style(editor, scroll: scroll, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? EditorTextView else { return }
        if editor.string != text, !editor.hasMarkedText() { editor.string = text; context.coordinator.restyle(immediately: true) }
        if context.coordinator.dark != (colorScheme == .dark) { style(editor, scroll: scroll, coordinator: context.coordinator) }
    }

    /// The same colors and type as the main editor (see `NativeCodeEditor.configure`).
    private func style(_ editor: EditorTextView, scroll: NSScrollView, coordinator: Coordinator) {
        let dark = colorScheme == .dark
        let palette = EditorPalette(presentation: presentation, effectiveDark: dark)
        let font = presentation.font(), paragraph = presentation.paragraphStyle()
        editor.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        editor.font = font; editor.defaultParagraphStyle = paragraph
        editor.textColor = palette.foreground; editor.backgroundColor = palette.background; editor.drawsBackground = true
        editor.insertionPointColor = palette.foreground
        editor.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.foreground]
        editor.typingAttributes = [.font: font, .foregroundColor: palette.foreground, .paragraphStyle: paragraph]
        editor.tabSize = presentation.tabSize
        scroll.backgroundColor = palette.background
        coordinator.dark = dark
        coordinator.highlighter.presentation = presentation; coordinator.highlighter.effectiveDark = dark
        coordinator.restyle(immediately: true)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IdeaTextView
        let highlighter = EditorSyntaxHighlighter()
        var dark = false
        init(_ parent: IdeaTextView) { self.parent = parent }
        func restyle(immediately: Bool = false) { highlighter.schedule(language: SyntaxLanguage(path: "idea.md"), immediately: immediately) }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            restyle()
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if let editor = textView as? EditorTextView, editor.overlays.isSlashOpen { return false }
            parent.onClose()
            return true
        }
    }
}
