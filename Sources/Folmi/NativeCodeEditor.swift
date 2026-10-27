import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit
import Darwin
import FolmiCore

/// A separate gutter avoids NSScrollView's initial overlay-ruler layout obscuring source text.
final class EditorContainer: NSView {
    let scroll: NSScrollView
    let ruler: EditorLineRuler
    var onLayout: (() -> Void)?
    init(scroll: NSScrollView, ruler: EditorLineRuler) {
        self.scroll = scroll; self.ruler = ruler
        super.init(frame: .zero)
        addSubview(ruler); addSubview(scroll)
        wantsLayer = true
    }
    func crossFade() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "documentSwitch")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let gutterWidth = min(bounds.width, ruler.ruleThickness)
        ruler.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scroll.frame = NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
        scroll.layoutSubtreeIfNeeded()
        onLayout?()
    }
}

struct NativeCodeEditor: NSViewRepresentable {
    @ObservedObject var workspace: EditorWorkspace
    let documentID: String
    @Binding var text: String
    @Binding var syntaxStatus: String
    /// The editor column this editor sits in; reveals and the reader hand-off only go to the active column.
    var column: UUID?
    @Environment(\.colorScheme) private var colorScheme
    private var effectiveDark: Bool { colorScheme == .dark }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> EditorContainer {
        context.coordinator.isUpdating = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let editor = EditorTextView(frame: .zero)
        editor.setAccessibilityIdentifier("file-editor")
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.allowsUndo = true; editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = []; editor.delegate = context.coordinator
        // A Markdown file opening in reading mode never shows this view first: no background layout, no first draw.
        let behindReader = Self.isMarkdownPath(documentID) && workspace.markdownReading
        editor.layoutManager?.backgroundLayoutEnabled = !behindReader
        editor.string = text; scroll.documentView = editor
        let ruler = EditorLineRuler(textView: editor, scrollView: scroll)
        let container = EditorContainer(scroll: scroll, ruler: ruler)
        container.isHidden = behindReader
        let coordinator = context.coordinator
        coordinator.editor = editor; coordinator.documentID = documentID; coordinator.ruler = ruler
        container.onLayout = { [weak coordinator, weak scroll] in
            guard let coordinator, let scroll, let editor = coordinator.editor as? EditorTextView, !coordinator.isDismantled else { return }
            if abs(coordinator.lastContentWidth - scroll.contentSize.width) > 0.5 {
                let wasUpdating = coordinator.isUpdating
                coordinator.isUpdating = true
                coordinator.parent.configureWrapping(editor: editor, scroll: scroll)
                coordinator.lastContentWidth = scroll.contentSize.width
                coordinator.isUpdating = wasUpdating
            }
            coordinator.ruler?.needsDisplay = true
        }
        coordinator.navigationRevision = workspace.navigationRevision
        coordinator.highlighter.editor = editor
        coordinator.highlighter.onStatus = { [weak coordinator] status in
            guard let coordinator else { return }
            let path = coordinator.documentID ?? ""
            let isMarkdown = ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased())
            coordinator.parent.syntaxStatus = isMarkdown ? "Markdown 源码" : status
            if status == "无高亮" || status.contains("词法高亮") { coordinator.navigationStyleFinished() }
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.recordState() }
        }
        configure(editor: editor, scroll: scroll)
        coordinator.lastPresentation = workspace.presentation; coordinator.lastDark = effectiveDark
        // A reveal may arrive before the native editor is first created (Cmd+P or search).
        // Do not consume it by initializing the coordinator to the same revision then restoring silently.
        coordinator.restorePosition(scroll: scroll, reveal: workspace.navigationRevision > 0)
        coordinator.isUpdating = false
        coordinator.style(immediately: true)
        ruler.onClickLine = { [weak coordinator] line, anchor in coordinator?.showPeek(line: line, anchor: anchor) }
        editor.focusChanged = { [weak coordinator] _ in coordinator?.scheduleNote(immediately: true) }
        editor.openBlameNote = { [weak coordinator] rect in coordinator?.openBlameCard(rect) }
        coordinator.indexRevisionSeen = workspace.indexRevision
        coordinator.showsLineBlameSeen = workspace.showsLineBlame
        coordinator.reloadIndexBase()
        coordinator.reloadBlame()
        return container
    }
    func updateNSView(_ container: EditorContainer, context: Context) {
        PerfLog.body("NativeCodeEditor.update")
        let updateStart = ContinuousClock.now
        defer { PerfLog.spend("NativeCodeEditor.update", since: updateStart) }
        let scroll = container.scroll
        let coordinator = context.coordinator
        guard let editor = scroll.documentView as? EditorTextView else { return }
        let switched = coordinator.documentID != documentID || coordinator.parent.workspace !== workspace
        if switched {
            // Selection and scroll notifications already store the last live state. Publishing
            // here would re-enter SwiftUI while it is updating the representable.
            if let previous = coordinator.documentID {
                coordinator.undoManagers[coordinator.parent.workspace.root.path + "\0" + previous] = coordinator.currentUndoManager
            }
        }
        let changedPresentation = coordinator.lastPresentation != workspace.presentation || coordinator.lastDark != effectiveDark
        // AppKit reports no text change until an input-method composition is committed, so the binding lags behind the
        // marked text. Writing the binding back during composition would discard it (pinyin, kana, etc.).
        let composing = editor.hasMarkedText()
        let changedText = editor.string != text && !composing
        coordinator.parent = self
        coordinator.isUpdating = true
        // Behind the reading view the source is invisible: loading the text, laying it out, styling and marking it
        // there is what made opening a Markdown file slow (≈30 ms from a code file). It all waits until the editor
        // comes forward; `deferredLoad` then counts as a switch to this document.
        let behindReader = Self.isMarkdownPath(documentID) && workspace.markdownReading
        if switched {
            coordinator.documentID = documentID
            coordinator.currentUndoManager = coordinator.undoManagers[workspace.root.path + "\0" + documentID] ?? UndoManager()
            if composing { editor.unmarkText(); editor.inputContext?.discardMarkedText() }
            editor.overlays.hideAll()
        }
        let deferLoad = behindReader && (switched || changedText || changedPresentation || coordinator.deferredLoad)
        let loadNow = !behindReader && coordinator.deferredLoad
        if deferLoad {
            if switched || changedText { container.isHidden = true }
            coordinator.deferredLoad = true
        } else if switched || loadNow {
            // Opening or switching a file cross-fades from the old text instead of cutting to it.
            if switched { container.crossFade() }
            coordinator.deferredLoad = false
            editor.string = text
            coordinator.ruler?.textChanged()
        } else if changedText {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(EditorTextPosition.clamp(selection, in: text))
            coordinator.ruler?.textChanged()
        }
        if deferLoad {
        } else if changedPresentation || switched || loadNow {
            if editor.hasMarkedText() { coordinator.deferConfiguration(scroll: scroll) }
            else { configure(editor: editor, scroll: scroll) }
        }
        else if abs(coordinator.lastContentWidth - scroll.contentSize.width) > 0.5 { configureWrapping(editor: editor, scroll: scroll) }
        coordinator.lastContentWidth = scroll.contentSize.width
        let workspacePrefix = workspace.root.path + "\0"
        let openIDs = Set(workspace.documents.map(\.id))
        coordinator.undoManagers = coordinator.undoManagers.filter { key, _ in
            !key.hasPrefix(workspacePrefix) || openIDs.contains(String(key.dropFirst(workspacePrefix.count)))
        }
        coordinator.isUpdating = false
        let navigation = coordinator.navigationRevision != workspace.navigationRevision
            && (workspace.navigationColumn == nil || column == nil || workspace.navigationColumn == column)
        coordinator.navigationRevision = workspace.navigationRevision
        if behindReader {
            if switched || navigation { coordinator.deferredRestore = true; coordinator.deferredReveal = coordinator.deferredReveal || navigation }
        } else if switched || navigation || coordinator.deferredRestore {
            let reveal = navigation || coordinator.deferredReveal
            coordinator.deferredRestore = false; coordinator.deferredReveal = false
            coordinator.restorePosition(scroll: scroll, reveal: reveal)
        }
        let restyle = changedPresentation || switched || changedText || loadNow
        if behindReader {
            if restyle { coordinator.deferredStyle = true }
        } else if restyle || coordinator.deferredStyle {
            coordinator.style(immediately: true)
            coordinator.deferredStyle = false
        }
        coordinator.lastPresentation = workspace.presentation; coordinator.lastDark = effectiveDark
        if behindReader {
            // Gutter marks are only drawn by the source view; the reader loads its own.
        } else if switched || coordinator.indexRevisionSeen != workspace.indexRevision || coordinator.indexRevisionSeen == .max {
            coordinator.indexRevisionSeen = workspace.indexRevision
            coordinator.reloadIndexBase()
            coordinator.reloadBlame()
        } else if changedText { coordinator.scheduleMarks() }
        if coordinator.showsLineBlameSeen != workspace.showsLineBlame {
            coordinator.showsLineBlameSeen = workspace.showsLineBlame
            coordinator.scheduleNote(immediately: true)
        }
        if behindReader && switched { coordinator.indexRevisionSeen = .max }
        editor.layoutManager?.backgroundLayoutEnabled = !behindReader
        coordinator.ruler?.needsDisplay = true
        coordinator.updateActive(!(Self.isMarkdownPath(documentID) && workspace.markdownReading), container: container, switched: switched)
    }
    static func isMarkdownPath(_ path: String) -> Bool { ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased()) }
    static func dismantleNSView(_ container: EditorContainer, coordinator: Coordinator) {
        container.onLayout = nil
        // Live NSTextView notifications have already captured the session. Never publish
        // ObservableObject state while GraphHost is destroying this representable.
        coordinator.isDismantled = true
        coordinator.isUpdating = true
        coordinator.restorationRevision &+= 1
        if let observer = coordinator.scrollObserver { NotificationCenter.default.removeObserver(observer) }
        coordinator.scrollObserver = nil
        coordinator.pendingConfiguration?.cancel()
        coordinator.pendingConfiguration = nil
        coordinator.pendingFocus?.cancel()
        coordinator.pendingFocus = nil
        coordinator.highlighter.cancel(); coordinator.cancelOutline()
        coordinator.baseTask?.cancel(); coordinator.marksTask?.cancel(); coordinator.peek?.close()
        coordinator.blameTask?.cancel(); coordinator.noteTask?.cancel(); coordinator.blameCard?.close()
        (coordinator.editor as? EditorTextView)?.focusChanged = nil
        (coordinator.editor as? EditorTextView)?.openBlameNote = nil
        coordinator.ruler?.onClickLine = nil
        coordinator.highlighter.editor = nil; coordinator.highlighter.onStatus = nil
        (coordinator.editor as? EditorTextView)?.toggleMarkdown = nil
        coordinator.editor?.delegate = nil
        coordinator.editor = nil
    }
    private func configure(editor: EditorTextView, scroll: NSScrollView) {
        let presentation = workspace.presentation
        let palette = EditorPalette(presentation: presentation, effectiveDark: effectiveDark)
        editor.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        editor.setAccessibilityLabel("编辑 \(documentID)")
        let font = presentation.font()
        let paragraph = presentation.paragraphStyle()
        editor.font = font; editor.defaultParagraphStyle = paragraph
        editor.textColor = palette.foreground; editor.backgroundColor = palette.background
        editor.insertionPointColor = palette.foreground
        editor.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.foreground]
        editor.typingAttributes = [.font: font, .foregroundColor: palette.foreground, .paragraphStyle: paragraph]
        editor.tabSize = presentation.tabSize
        editor.sendSelection = { [weak workspace] range in workspace?.sendSelectionToTerminal?(range) }
        // configure runs on every document switch, so the path captured here is the open one.
        let path = documentID
        editor.assistSelection = { [weak workspace] mode, text in workspace?.assistSelection?(mode, text, path) }
        editor.showCalls = FolmiModel.callMapExtensions.contains((documentID as NSString).pathExtension.lowercased())
            ? { [weak workspace, weak editor] location in
                guard let editor, let document = workspace?.documents.first(where: { $0.id == path }) else { return }
                workspace?.showCallsAt?(document.path, editor.string, location)
            } : nil
        if ["md", "markdown", "mdown"].contains((documentID as NSString).pathExtension.lowercased()) {
            editor.toggleMarkdown = { [weak workspace] in workspace?.markdownReading.toggle() }
            editor.markdownEditing = true
            editor.openLink = { [weak workspace, documentID] target in workspace?.followLink(target, from: documentID) }
            editor.importImages = { [weak workspace, documentID] files, png in workspace?.imageMarkdown(files: files, png: png, for: documentID) }
            editor.imageFile = { [weak workspace, documentID] target in workspace?.imageURL(target, from: documentID) }
            editor.imageLink = { [weak workspace, documentID] file in
                guard let workspace else { return nil }
                do { return try workspace.imageLink(for: file, from: documentID) }
                catch { workspace.errorMessage = "图片没有替换：\(error.localizedDescription)"; return nil }
            }
            editor.wikiCompletions = { [weak workspace] partial in workspace?.wikiNames(matching: partial) ?? [] }
            editor.onNotice = { [weak workspace] message in workspace?.showNotice(message) }
            editor.overlays.style = { [weak workspace] in (workspace?.presentation.theme ?? .standard, workspace?.glassSurfaces ?? true) }
        } else {
            // A non-Markdown editor must pass Option-layout text input through normally.
            editor.toggleMarkdown = nil
            editor.markdownEditing = false
            editor.openLink = nil
            editor.importImages = nil
            editor.imageFile = nil
            editor.imageLink = nil
            editor.wikiCompletions = nil
            editor.onNotice = nil
            editor.overlays.hideAll()
        }
        scroll.backgroundColor = palette.background
        (scroll.superview as? EditorContainer)?.ruler.palette = palette
        configureWrapping(editor: editor, scroll: scroll)
    }
    private func configureWrapping(editor: NSTextView, scroll: NSScrollView) {
        let wraps = workspace.presentation.wrapLines
        scroll.hasHorizontalScroller = !wraps
        scroll.tile()
        editor.setFrameOrigin(.zero)
        editor.setBoundsOrigin(.zero)
        editor.minSize = NSSize(width: max(0, scroll.contentSize.width), height: max(0, scroll.contentSize.height))
        editor.isHorizontallyResizable = !wraps
        let side: CGFloat = 10
        if editor.textContainerInset.width != side { editor.textContainerInset = NSSize(width: side, height: 10) }
        editor.textContainer?.widthTracksTextView = wraps
        editor.textContainer?.containerSize = NSSize(width: wraps ? max(1, scroll.contentSize.width - side * 2) : CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = !wraps
        if wraps {
            editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(editor.frame.height, scroll.contentSize.height)))
            // AppKit can carry a pre-ruler horizontal offset through the first layout.
            // Wrapped text always starts at its left inset; horizontal offsets are never session state.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCodeEditor
        weak var editor: NSTextView?
        weak var ruler: EditorLineRuler?
        var documentID: String?
        var isUpdating = false
        var isDismantled = false
        var restoringPosition = false
        var navigationRevision: UInt64 = 0
        var restorationRevision: UInt64 = 0
        var lastPresentation: EditorPresentation?
        var lastDark = false
        var lastContentWidth: CGFloat = 0
        var scrollObserver: NSObjectProtocol?
        var pendingConfiguration: Task<Void, Never>?
        var pendingFocus: Task<Void, Never>?
        var navigationAwaitingStyle: UInt64?
        var undoManagers: [String: UndoManager] = [:]
        var currentUndoManager = UndoManager()
        let highlighter = EditorSyntaxHighlighter()
        init(_ parent: NativeCodeEditor) { self.parent = parent }
        func deferConfiguration(scroll: NSScrollView) {
            pendingConfiguration?.cancel()
            pendingConfiguration = Task { @MainActor [weak self, weak scroll] in
                while let editor = self?.editor, editor.hasMarkedText() {
                    do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                }
                guard !Task.isCancelled, let self, !self.isDismantled, let scroll, let editor = self.editor as? EditorTextView else { return }
                self.parent.configure(editor: editor, scroll: scroll)
                self.style(immediately: true)
            }
        }
        var active: Bool?
        private var hideWork: DispatchWorkItem?

        /// Shown or behind the reading view. Becoming visible applies the reader's place and takes keyboard focus;
        /// going behind hides the view once the fade is over, so focus and clicks never land in it.
        func updateActive(_ active: Bool, container: EditorContainer, switched: Bool) {
            if active, parent.column == nil || parent.column == parent.workspace.columns.activeID {
                parent.workspace.editorTopLine = { [weak self] in self?.topVisibleLine() }
            }
            guard self.active != active || (active && switched && parent.workspace.editorScrollRequest?.id == documentID) else { return }
            let first = self.active == nil
            self.active = active
            hideWork?.cancel()
            if active {
                container.isHidden = false
                guard !first || parent.workspace.editorScrollRequest != nil else { return }
                applyScrollRequest(container: container)
            } else if switched {
                // Another document (code → Markdown): the text is already the new source, so fading it out would only
                // lay out and draw the whole document, gutter included, under the reader. Hide it in this frame.
                container.isHidden = true
            } else {
                let work = DispatchWorkItem { [weak self, weak container] in
                    guard let self, self.active == false else { return }
                    container?.isHidden = true
                }
                hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (first ? 0 : 0.25), execute: work)
            }
        }

        private func applyScrollRequest(container: EditorContainer) {
            guard let editor, let documentID else { return }
            let request = parent.workspace.editorScrollRequest
            parent.workspace.editorScrollRequest = nil
            let state = parent.workspace.tabStates[documentID]
            restoringPosition = true
            if let state { editor.setSelectedRange(EditorTextPosition.clamp(NSRange(location: state.selectionLocation, length: state.selectionLength), in: editor.string)) }
            Task { @MainActor [weak self, weak container] in
                guard let self, !self.isDismantled, let editor = self.editor, let scroll = editor.enclosingScrollView, self.documentID == documentID else { return }
                if let request, request.id == documentID, let layout = editor.layoutManager, let textContainer = editor.textContainer {
                    layout.ensureLayout(for: textContainer)
                    let height = max(scroll.contentSize.height, layout.usedRect(for: textContainer).maxY + editor.textContainerInset.height * 2)
                    editor.setFrameSize(NSSize(width: max(editor.frame.width, scroll.contentSize.width), height: height))
                    let starts = MarkdownReaderView.Coordinator.lineStarts(editor.string)
                    let location = starts[max(0, min(request.line, starts.count - 1))]
                    let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: min(location, (editor.string as NSString).length), length: 0), actualCharacterRange: nil)
                    let rect = layout.lineFragmentRect(forGlyphAt: min(glyphs.location, max(0, layout.numberOfGlyphs - 1)), effectiveRange: nil)
                    let y = request.line == 0 ? 0 : min(max(0, editor.frame.height - scroll.contentSize.height), max(0, rect.minY + editor.textContainerOrigin.y - 8))
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                }
                self.restoringPosition = false
                self.recordState()
                if container?.window != nil { editor.window?.makeFirstResponder(editor) }
            }
        }

        /// The line at the top of the visible text, 0-based.
        func topVisibleLine() -> Int? {
            guard let editor, let layout = editor.layoutManager, let textContainer = editor.textContainer,
                  let scroll = editor.enclosingScrollView, layout.numberOfGlyphs > 0 else { return nil }
            let y = max(0, scroll.contentView.bounds.minY - editor.textContainerOrigin.y + 4)
            let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: textContainer)
            let character = layout.characterIndexForGlyph(at: glyph)
            let starts = MarkdownReaderView.Coordinator.lineStarts(editor.string)
            return starts.lastIndex { $0 <= character } ?? 0
        }

        func recordState() {
            guard !isDismantled, !isUpdating, !restoringPosition, let editor, let documentID else { return }
            let selection = editor.selectedRange()
            let scroll = Double(editor.enclosingScrollView?.contentView.bounds.minY ?? 0)
            parent.workspace.updateEditorState(id: documentID, selection: selection, scrollOffset: scroll)
        }
        func restorePosition(scroll: NSScrollView, reveal: Bool) {
            guard let editor, let documentID else { return }
            let state = parent.workspace.tabStates[documentID] ?? EditorTabState(path: documentID)
            restoringPosition = true
            pendingFocus?.cancel()
            restorationRevision &+= 1
            let expectedRestoration = restorationRevision
            navigationAwaitingStyle = reveal ? expectedRestoration : nil
            editor.setSelectedRange(EditorTextPosition.clamp(NSRange(location: state.selectionLocation, length: state.selectionLength), in: editor.string))
            // Layout must reflect wrapping and current type before a bounded scroll position can be restored.
            Task { @MainActor [weak self, weak scroll] in
                guard let self, !self.isDismantled, let scroll, let editor = self.editor, self.documentID == documentID, self.restorationRevision == expectedRestoration else { return }
                if let container = editor.textContainer, let layout = editor.layoutManager {
                    layout.ensureLayout(for: container)
                    let height = max(scroll.contentSize.height, layout.usedRect(for: container).maxY + editor.textContainerInset.height * 2)
                    editor.setFrameSize(NSSize(width: max(editor.frame.width, scroll.contentSize.width), height: height))
                }
                if reveal { editor.scrollRangeToVisible(editor.selectedRange()) }
                else {
                    let maximum = max(0, editor.frame.height - scroll.contentSize.height)
                    let y = min(maximum, CGFloat(state.scrollOffset.isFinite ? max(0, state.scrollOffset) : 0))
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                }
                self.restoringPosition = false
                self.recordState()
                if reveal { self.focusAfterPresentation(scroll: scroll, revision: expectedRestoration) }
                self.style(immediately: true)
            }
        }
        func navigationStyleFinished() {
            guard let revision = navigationAwaitingStyle, revision == restorationRevision,
                  let scroll = editor?.enclosingScrollView, !isDismantled else { return }
            navigationAwaitingStyle = nil
            // Markdown can change line heights after the initial plain-text layout.
            focusAfterPresentation(scroll: scroll, revision: revision)
        }
        func focusAfterPresentation(scroll: NSScrollView, revision: UInt64) {
            pendingFocus?.cancel()
            pendingFocus = Task { @MainActor [weak self, weak scroll] in
                // A quick-open/search sheet may still be dismissing while its destination is built.
                // Wait for the owning window, then focus once. New navigation/teardown cancels this request.
                for _ in 0..<40 {
                    guard !Task.isCancelled, let self, !self.isDismantled,
                          self.restorationRevision == revision, let scroll, let editor = self.editor else { return }
                    if let window = editor.window, window.attachedSheet == nil, window.makeFirstResponder(editor) {
                        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
                        editor.scrollRangeToVisible(editor.selectedRange())
                        if self.parent.workspace.presentation.wrapLines {
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                        self.recordState()
                        return
                    }
                    do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                }
            }
        }
        func style(immediately: Bool = false) {
            guard !isDismantled, editor != nil else { return }
            if isMarkdownFile { scheduleOutline(immediately: immediately) }
            highlighter.presentation = parent.workspace.presentation; highlighter.effectiveDark = parent.effectiveDark
            highlighter.schedule(language: SyntaxLanguage(path: documentID ?? ""), immediately: immediately)
            ruler?.needsDisplay = true
        }
        func textDidChange(_ notification: Notification) {
            guard !isDismantled, !isUpdating, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            ruler?.textChanged()
            recordState(); style(); scheduleMarks()
            textChangedForNote()
        }

        // MARK: Outline

        var isMarkdownFile: Bool { ["md", "markdown", "mdown"].contains(((documentID ?? "") as NSString).pathExtension.lowercased()) }
        private var outlineTask: Task<Void, Never>?

        /// Source mode has no styling pass, so the outline gets its headings from a debounced background scan.
        func scheduleOutline(immediately: Bool) {
            outlineTask?.cancel()
            guard let editor, let documentID else { return }
            let text = editor.string
            outlineTask = Task { @MainActor [weak self] in
                if !immediately { do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return } }
                let layout = await Task.detached(priority: .utility) { MarkdownOutline.layout(text) }.value
                guard let self, !Task.isCancelled, !self.isDismantled, self.documentID == documentID, let editor = self.editor else { return }
                self.parent.workspace.outline(for: self.parent.column).update(documentID: documentID, layout: layout, caret: editor.selectedRange().location)
            }
        }

        // MARK: Gutter change marks against the index

        var indexBase: IndexBase?
        var indexRevisionSeen: UInt64 = 0
        /// Work skipped while the source sat behind the reading view, done when it comes forward.
        /// The text and configuration were not loaded while this editor sat behind the reading view.
        var deferredLoad = false
        var deferredRestore = false
        var deferredReveal = false
        var deferredStyle = false
        var baseTask: Task<Void, Never>?
        var marksTask: Task<Void, Never>?
        var peek: NSPopover?

        func reloadIndexBase() {
            baseTask?.cancel()
            guard let path = documentID, let loader = parent.workspace.loadIndexBase else {
                indexBase = nil; ruler?.marks = GutterDiff.Marks(); return
            }
            baseTask = Task { @MainActor [weak self] in
                let base = await loader(path)
                guard let self, !Task.isCancelled, !self.isDismantled, self.documentID == path else { return }
                self.indexBase = base
                self.scheduleMarks(immediately: true)
                self.scheduleNote(immediately: true)
            }
        }

        func scheduleMarks(immediately: Bool = false) {
            marksTask?.cancel()
            guard let base = indexBase, base.path == documentID, let editor else { ruler?.marks = GutterDiff.Marks(); return }
            let current = editor.string, baseText = base.text
            marksTask = Task { @MainActor [weak self] in
                if !immediately {
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                }
                let changes = await Task.detached(priority: .userInitiated) { GutterDiff.changes(base: baseText, current: current) }.value
                guard let self, !Task.isCancelled, !self.isDismantled, self.editor?.string == current else { return }
                self.ruler?.marks = GutterDiff.Marks(changes)
            }
        }

        func showPeek(line: Int, anchor: NSRect) {
            guard let ruler, let base = indexBase, let editor, let change = ruler.marks.change(atLine: line) else { return }
            let baseLines = GutterDiff.lines(base.text)
            guard change.old.upperBound <= baseLines.count else { return }
            let kind = change.isInsertion ? "新增 \(change.new.count) 行" : change.isDeletion ? "删除 \(change.old.count) 行" : "修改 \(change.old.count) → \(change.new.count) 行"
            let canStage = parent.workspace.stageIndexText != nil && !base.mixedNewlines
            let stageHelp = base.mixedNewlines ? "暂存区版本混用了多种换行符，请在「差异」里按块暂存。" :
                "只把这一段写进暂存区，包括尚未保存的编辑；其余行保持暂存区原样。"
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: GutterPeekView(
                path: base.path, removed: Array(baseLines[change.old]), kind: kind, canStage: canStage, stageHelp: stageHelp,
                onRevert: { [weak self, weak popover] in self?.revert(change); popover?.close() },
                onStage: { [weak self, weak popover] in self?.stage(change); popover?.close() }))
            peek?.close()
            peek = popover
            _ = editor
            popover.show(relativeTo: anchor, of: ruler, preferredEdge: .maxX)
        }

        /// Only acts when the change is still exactly what the gutter showed.
        private func currentChange(_ change: LineDiff.Change) -> IndexBase? {
            guard let base = indexBase, let editor, GutterDiff.changes(base: base.text, current: editor.string).contains(change) else {
                scheduleMarks(immediately: true); return nil
            }
            return base
        }

        func revert(_ change: LineDiff.Change) {
            guard let base = currentChange(change), let editor,
                  let edit = GutterDiff.revert(base: base.text, current: editor.string, change: change) else { return }
            // insertText goes through shouldChangeText, so the revert is one undo step.
            editor.insertText(edit.replacement, replacementRange: edit.range)
        }

        func stage(_ change: LineDiff.Change) {
            guard let base = currentChange(change), let editor, let write = parent.workspace.stageIndexText, !base.mixedNewlines else { return }
            write(base, base.encoded(GutterDiff.staged(base: base.text, current: editor.string, change: change)))
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isDismantled, !isUpdating, !restoringPosition else { return }
            recordState()
            if let editor, isMarkdownFile { parent.workspace.outline(for: parent.column).updateCaret(editor.selectedRange().location) }
            scheduleNote()
        }

        // MARK: Note after the caret's line (who last changed it)

        var blameSource: LineBlame.Source = .unavailable
        var blamePath: String?
        var blameTask: Task<Void, Never>?
        var noteTask: Task<Void, Never>?
        var showsLineBlameSeen = true
        /// The buffer mapped onto HEAD and onto the index, kept until the text or either base changes.
        private var lineMaps: (text: String, head: String?, headMap: [Int?], index: String?, indexMap: [Int?])?
        private(set) var note: LineBlameNote?
        var blameCard: NSPopover?

        func reloadBlame() {
            blameTask?.cancel()
            guard let path = documentID, let loader = parent.workspace.loadBlame else {
                blameSource = .unavailable; blamePath = nil; setNote(nil, range: nil); return
            }
            if blamePath != path { blameSource = .unavailable; blamePath = path; setNote(nil, range: nil) }
            blameTask = Task { @MainActor [weak self] in
                let source = await loader(path)
                guard let self, !Task.isCancelled, !self.isDismantled, self.documentID == path else { return }
                if !Self.sameSource(source, self.blameSource) { self.blameSource = source }
                self.scheduleNote(immediately: true)
            }
        }

        private static func sameSource(_ a: LineBlame.Source, _ b: LineBlame.Source) -> Bool {
            switch (a, b) {
            case let (.blame(x), .blame(y)): return x.head == y.head && x.path == y.path
            case (.notInHead, .notInHead), (.unavailable, .unavailable): return true
            default: return false
            }
        }

        /// Shown once the caret has rested on one line; hidden while typing, composing, selecting several lines,
        /// or when the editor is not focused.
        func scheduleNote(immediately: Bool = false) {
            noteTask?.cancel()
            guard let editor = editor as? EditorTextView, !isDismantled, let path = documentID, blamePath == path,
                  parent.workspace.showsLineBlame, editor.window?.firstResponder === editor, !editor.hasMarkedText(),
                  editor.enclosingScrollView?.isFindBarVisible != true else { setNote(nil, range: nil); return }
            let source = blameSource
            let base = indexBase?.path == path ? indexBase : nil
            // Untracked: nothing to say. Git could not answer: say nothing rather than something wrong.
            if case .unavailable = source { setNote(nil, range: nil); return }
            if case .notInHead = source, base == nil { setNote(nil, range: nil); return }
            let text = editor.string, ns = text as NSString
            let selection = editor.selectedRange()
            guard NSMaxRange(selection) <= ns.length, selection.location < ns.length || (ns.length > 0 && !text.hasSuffix("\n")) else {
                setNote(nil, range: nil); return
            }
            let lineRange = ns.lineRange(for: NSRange(location: min(selection.location, max(0, ns.length - 1)), length: 0))
            guard NSMaxRange(selection) <= NSMaxRange(lineRange) else { setNote(nil, range: nil); return }
            // Moving within the line keeps the note; anything else hides it until the caret rests again.
            let keep = editor.blameNote?.range == lineRange && note != nil && lineMaps?.text == text
            if !keep { setNote(nil, range: nil) }
            let headText: String? = { if case .blame(let blame) = source { return blame.text } else { return nil } }()
            let indexText = base?.text
            let cached = lineMaps
            noteTask = Task { @MainActor [weak self] in
                if !immediately && !keep {
                    do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                }
                let location = lineRange.location
                let (maps, line) = await Task.detached(priority: .userInitiated) { () -> ((text: String, head: String?, headMap: [Int?], index: String?, indexMap: [Int?]), Int) in
                    let reuse = cached.map { $0.text == text } ?? false
                    let headMap = reuse && cached?.head == headText ? cached!.headMap : headText.map { LineBlame.headLines(head: $0, current: text) } ?? []
                    let indexMap = reuse && cached?.index == indexText ? cached!.indexMap : indexText.map { LineBlame.headLines(head: $0, current: text) } ?? []
                    let line = (text as NSString).substring(to: location).utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
                    return ((text, headText, headMap, indexText, indexMap), line)
                }.value
                guard let self, !Task.isCancelled, !self.isDismantled, let editor = self.editor as? EditorTextView,
                      editor.string == text, editor.selectedRange() == selection, self.documentID == path else { return }
                self.lineMaps = maps
                let headLine = line < maps.headMap.count ? maps.headMap[line] : nil
                let staged = line < maps.indexMap.count && maps.indexMap[line] != nil
                self.setNote(LineBlame.note(line: line, source: source, headLine: headLine, unstaged: !staged), range: lineRange)
            }
        }

        func setNote(_ note: LineBlameNote?, range: NSRange?) {
            self.note = note
            guard let editor = editor as? EditorTextView else { return }
            if let note, let range { editor.blameNote = EditorTextView.LineNote(range: range, text: note.text, opens: note.commit != nil) }
            else { editor.blameNote = nil }
        }

        func textChangedForNote() {
            setNote(nil, range: nil)
            blameCard?.close()
            scheduleNote()
        }

        func openBlameCard(_ rect: NSRect) {
            guard blameCard?.isShown != true, let editor, let note, let commit = note.commit, let path = documentID else { return }
            let workspace = parent.workspace
            let history: (() async -> [FileBlame.Commit])? = workspace.loadLineHistory.flatMap { loader in
                note.headLine.map { line in { await loader(path, line + 1, line + 1) } }
            }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: LineBlameCard(
                commit: commit, isMine: note.isMine, loadHistory: history,
                onShowCommit: { [weak popover, weak workspace] id in popover?.close(); workspace?.showCommit?(id) }))
            blameCard = popover
            popover.show(relativeTo: rect, of: editor, preferredEdge: .maxY)
        }
        func undoManager(for view: NSTextView) -> UndoManager? { currentUndoManager }
        func cancelOutline() { outlineTask?.cancel(); outlineTask = nil }
    }
}

final class EditorLineRuler: NSView {
    weak var textView: NSTextView?
    var palette: EditorPalette?
    let ruleThickness: CGFloat = 46
    var marks = GutterDiff.Marks() { didSet { if marks != oldValue { needsDisplay = true } } }
    var onClickLine: ((Int, NSRect) -> Void)?
    /// UTF-16 offsets where each line starts, rebuilt lazily after the text changes. Drawing starts at the first visible
    /// line instead of walking the document from its top on every scroll frame.
    private var lineStarts: [Int]?
    func textChanged() { lineStarts = nil; needsDisplay = true }
    private func starts(_ text: NSString) -> [Int] {
        if let lineStarts, lineStarts.last.map({ $0 <= text.length }) == true { return lineStarts }
        var result = [0]
        let length = text.length
        var buffer = [unichar](repeating: 0, count: length)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        var index = 0
        while index < length {
            let character = buffer[index]
            if character == 10 || character == 13 {
                if character == 13, index + 1 < length, buffer[index + 1] == 10 { index += 1 }
                result.append(index + 1)
            }
            index += 1
        }
        // A final newline starts the empty extra line, which is drawn separately.
        if result.count > 1, result.last == length { result.removeLast() }
        lineStarts = result
        return result
    }
    /// The 0-based line holding `location`.
    private func line(at location: Int, in starts: [Int]) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= location { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(frame: .zero)
        setAccessibilityIdentifier("editor-line-gutter")
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func redraw() { needsDisplay = true }
    override var isFlipped: Bool { true }
    static let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    override func draw(_ rect: NSRect) {
        guard let editor = textView, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        (palette?.gutter ?? NSColor.controlBackgroundColor).setFill()
        bounds.fill()
        let visible = editor.visibleRect
        let origin = editor.textContainerOrigin
        let text = editor.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: palette?.comment ?? NSColor.secondaryLabelColor
        ]
        let lineStarts = starts(text)
        // Start at the first line in view; nothing above it is drawn.
        let top = NSRect(x: 0, y: visible.minY - origin.y, width: max(1, container.size.width), height: 1)
        let firstGlyph = layout.glyphRange(forBoundingRect: top, in: container).location
        let firstCharacter = min(text.length, layout.characterIndexForGlyph(at: firstGlyph))
        var firstLine = text.length == 0 ? 0 : line(at: firstCharacter, in: lineStarts)
        // A wrapped or hidden line may begin above the view; back up one so its label and marks still draw.
        if firstLine > 0 { firstLine -= 1 }
        var index = firstLine < lineStarts.count ? lineStarts[firstLine] : text.length
        var number = firstLine + 1
        var lastLabelY = -CGFloat.greatestFiniteMagnitude
        while index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: index)
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            let y = lineRect.minY + origin.y - visible.minY
            if y > bounds.maxY { break }
            if y + lineRect.height >= 0 { drawMark(line: number - 1, y: y, lineRange: lineRange, layout: layout, container: container) }
            // On the line's first baseline, like the text: a tall Markdown line keeps its number beside its words, and
            // the number scrolls out of view together with them instead of lingering at the fragment's top.
            let labelY = y + layout.location(forGlyphAt: glyph).y - Self.labelFont.ascender
            if lineRect.height >= 8, labelY + Self.labelFont.ascender >= 0, labelY >= lastLabelY + 11 {
                let label = String(number) as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: labelY), withAttributes: attributes)
                lastLabelY = labelY
            }
            index = NSMaxRange(lineRange)
            number += 1
        }
        if text.length == 0 || text.hasSuffix("\n") {
            let extra = layout.extraLineFragmentRect
            let y = extra.minY + origin.y - visible.minY
            if y >= 0, y < bounds.maxY {
                if marks.deletionsBefore.contains(number - 1) { drawDeletion(y: y) }
                let label = String(number) as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + 1), withAttributes: attributes)
            }
        }
        _ = container
    }

    private func drawMark(line: Int, y: CGFloat, lineRange: NSRange, layout: NSLayoutManager, container: NSTextContainer) {
        if let kind = marks.lineKinds[line] {
            // A wrapped line spans several fragments; mark all of them.
            let glyphs = layout.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let height = max(layout.boundingRect(forGlyphRange: glyphs, in: container).height, 4)
            (kind == .added ? ThemePalette.current.added : ThemePalette.current.accent).withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: y, width: 3, height: height), xRadius: 1, yRadius: 1).fill()
        }
        if marks.deletionsBefore.contains(line) { drawDeletion(y: y) }
    }

    private func drawDeletion(y: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: y - 4)); path.line(to: NSPoint(x: 6, y: y)); path.line(to: NSPoint(x: 0, y: y + 4)); path.close()
        ThemePalette.current.removed.withAlphaComponent(0.85).setFill()
        path.fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let editor = textView, let layout = editor.layoutManager, let container = editor.textContainer,
              !marks.changes.isEmpty else {
            return super.mouseDown(with: event)
        }
        let point = convert(event.locationInWindow, from: nil)
        let textPoint = NSPoint(x: 0, y: point.y + editor.visibleRect.minY - editor.textContainerOrigin.y)
        let text = editor.string as NSString
        let line: Int
        let extra = layout.extraLineFragmentRect
        if text.length == 0 || (!extra.isEmpty && textPoint.y >= extra.minY) {
            // The empty line after a final newline (where an end-of-file deletion is marked).
            line = text.length == 0 ? 0 : starts(text).count - (text.hasSuffix("\n") ? 0 : 1)
        } else {
            let character = min(layout.characterIndexForGlyph(at: layout.glyphIndex(for: textPoint, in: container)), text.length)
            line = self.line(at: character, in: starts(text))
        }
        onClickLine?(line, NSRect(x: 0, y: point.y - 6, width: ruleThickness, height: 12))
    }
}
