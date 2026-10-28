import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Views

enum MarkdownFormatAction: Equatable {
    case bold, italic, strike, code, link, heading(Int)
}

/// What the AI buttons over a selection do with it.
enum EditorSelectionAction: Equatable {
    /// The small card; a preset question is asked right away.
    case ask(String?)
    /// Into the agent's composer as an attachment, not sent.
    case handToAgent
}

/// 问 / 交给 Codex over a selection, alone in a code editor or after the format buttons in Markdown.
struct SelectionAIButtons: View {
    let agentTitle: String
    /// Code gets 解释; Markdown has 说人话 and 翻译 in its menu already.
    var explains = false
    let perform: (EditorSelectionAction) -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("问", help: "就选中的内容问 AI（⌘L）") { perform(.ask(nil)) }
            button("交给 \(agentTitle)", help: "作为附件放进 \(agentTitle) 会话的输入框，不会直接发送（⌘J）") { perform(.handToAgent) }
            if explains {
                button("解释", help: "让 AI 用几句话说明这段代码") { perform(.ask(Self.explainQuestion)) }
            }
        }
    }

    static let explainQuestion = "这段代码在做什么？有没有明显的问题？"

    /// A few characters or more: a stray click-drag over one letter is not a question.
    static func worthShowing(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }

    private func button(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).themedFont(.system(size: 12, weight: .medium), points: 12).padding(.horizontal, 6).frame(height: 24)
        }
        .buttonStyle(.plain).help(help)
    }
}

/// The bar over a text selection. It never holds text; each button runs the same command as its shortcut.
struct MarkdownFormatBar: View {
    /// nil in a code editor or a code block: only the AI buttons show.
    let state: MarkdownCommands.FormatState?
    var ai: SelectionAIButtons?
    let perform: (MarkdownFormatAction) -> Void

    var body: some View {
        HStack(spacing: 2) {
            if let state { formatButtons(state) }
            if let ai {
                if state != nil { Divider().frame(height: 16) }
                ai
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
        .folmiSurface(.popover, cornerRadius: 9)
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state == nil ? "选中内容" : "文字格式")
    }

    @ViewBuilder private func formatButtons(_ state: MarkdownCommands.FormatState) -> some View {
        Menu {
            Button("正文 ⌥⌘0") { perform(.heading(0)) }
            ForEach(1...6, id: \.self) { level in
                Button("标题 \(level)  ⌥⌘\(level)") { perform(.heading(level)) }
            }
        } label: {
            Text(state.heading == 0 ? "正文" : "标题 \(state.heading)").themedFont(.system(size: 12, weight: .medium), points: 12)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .padding(.horizontal, 6)
        .help("段落样式（⌥⌘0–6），对选中的每一行生效")
        Divider().frame(height: 16)
        button("bold", "粗体（⌘B）", on: state.bold, enabled: !state.multiline, action: .bold)
        button("italic", "斜体（⌘I）", on: state.italic, enabled: !state.multiline, action: .italic)
        button("strikethrough", "删除线（⌘⇧X）", on: state.strike, enabled: !state.multiline, action: .strike)
        button("chevron.left.forwardslash.chevron.right", "行内代码（⌘E）", on: state.code, enabled: !state.multiline, action: .code)
        button("link", "链接（⇧⌘K）", on: false, enabled: !state.multiline, action: .link)
    }

    private func button(_ symbol: String, _ help: String, on: Bool, enabled: Bool, action: MarkdownFormatAction) -> some View {
        MarkdownBarButton(symbol: symbol, help: help, on: on, enabled: enabled) { perform(action) }
    }
}

struct MarkdownBarButton: View {
    let symbol: String
    let help: String
    var on = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .foregroundStyle(on ? ThemeColor(token: .accent) : ThemeColor(token: .foreground))
                .themedBackground(on ? ThemeColor(token: .accent, opacity: 0.16) : ThemeColor(token: .hover, opacity: hovering ? 1 : 0), .control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The `/` menu. The editor keeps keyboard focus; arrows, Return, Tab and Esc reach the menu through it.
struct MarkdownSlashMenu: View {
    let commands: [MarkdownCommands.SlashCommand]
    let selected: Int
    let pick: (Int) -> Void
    static let rowHeight: CGFloat = 30
    static let visibleRows = 8

    var body: some View {
        Group {
            if commands.isEmpty {
                Text("没有匹配的命令").themedFont(.callout, points: 12).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight).padding(.vertical, 4)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                row(command, index: index).id(command.id)
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: selected) { _, value in
                        if commands.indices.contains(value) { proxy.scrollTo(commands[value].id) }
                    }
                }
            }
        }
        .frame(width: 248)
        .folmiSurface(.popover, cornerRadius: 10)
        .focusEffectDisabled()
        .accessibilityLabel("插入")
    }

    private func row(_ command: MarkdownCommands.SlashCommand, index: Int) -> some View {
        Button { pick(index) } label: {
            HStack(spacing: 9) {
                Image(systemName: command.symbol).font(.system(size: 12)).frame(width: 18)
                    .foregroundStyle(index == selected ? ThemeColor(token: .accent) : ThemeColor(token: .secondaryText))
                Text(command.title).themedFont(.system(size: 13), points: 13)
                Spacer(minLength: 4)
                Text(command.hint).themedFont(.system(size: 11).monospaced(), points: 11).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .themedBackground(ThemeColor(token: .selectedFill, opacity: index == selected ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(index == selected ? .isSelected : [])
    }
}

/// Language and copy for the fenced block holding the caret.
struct MarkdownCodeTools: View {
    let language: String
    let copied: Bool
    let setLanguage: (String) -> Void
    let copy: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(MarkdownCommands.codeLanguages, id: \.self) { name in Button(name) { setLanguage(name) } }
                Divider()
                Button("不标语言") { setLanguage("") }
            } label: {
                Text(language.isEmpty ? "语言" : language).themedFont(.system(size: 11, weight: .medium).monospaced(), points: 11)
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .padding(.horizontal, 6)
            .help("只改开头围栏上的语言名")
            Divider().frame(height: 14)
            Button(action: copy) {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .themedFont(.system(size: 11), points: 11).labelStyle(.titleAndIcon)
                    .padding(.horizontal, 6).frame(height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help("复制代码（不含围栏）")
        }
        .padding(.horizontal, 3).padding(.vertical, 2)
        .folmiSurface(.popover, cornerRadius: 8)
        .focusEffectDisabled()
    }
}

// MARK: - Overlay controller

/// Floating Markdown controls inside one editor. They are subviews of the text view, so they scroll with the text
/// and never take keyboard focus; the editor stays first responder and forwards keys while the `/` menu is open.
@MainActor
final class MarkdownOverlays {
    weak var editor: EditorTextView?
    /// Theme and glass for the floating views, read when they show.
    var style: (() -> (theme: FolmiTheme, glass: Bool))?
    /// Fenced-block ranges from the last styling pass; the code tools only look inside these.
    var fencedBlocks: (() -> [NSRange])?

    private var formatHost: NSHostingView<AnyView>?
    private var slashHost: NSHostingView<AnyView>?
    private var codeHost: NSHostingView<AnyView>?
    private var formatTarget: (selection: NSRange, text: String, revision: UInt64)?
    private var formatWork: DispatchWorkItem?
    private(set) var revision: UInt64 = 0

    // `/` menu state.
    private(set) var slashTrigger: NSRange?
    private(set) var slashMatches: [MarkdownCommands.SlashCommand] = []
    private(set) var slashSelected = 0
    private var dismissedTrigger: Int?

    // Code tools state.
    private var fence: MarkdownCommands.Fence?
    private var copiedFence: Int?

    var isSlashOpen: Bool { slashTrigger != nil }
    var isFormatBarShown: Bool { formatHost?.isHidden == false }

    /// Whether a point (in the editor's coordinates) is over one of the floating controls on screen.
    func covers(_ point: NSPoint) -> Bool {
        [formatHost, slashHost, codeHost].contains { host in
            guard let host, !host.isHidden, host.superview != nil else { return false }
            return host.frame.contains(point)
        }
    }

    func textChanged() {
        revision &+= 1
        hideFormatBar()
        guard editor?.markdownEditing == true else { return }
        refreshSlash()
        refreshCodeTools()
    }

    func selectionChanged(stillSelecting: Bool) {
        formatWork?.cancel()
        hideFormatBar()
        // A code editor has only the AI buttons, and they follow the mouse alone (mouseUp), not Shift-arrows.
        guard editor?.markdownEditing == true else { return }
        refreshSlash()
        refreshCodeTools()
        guard !stillSelecting, let editor, editor.selectedRange().length > 0 else { return }
        // Wait for a mouse drag or a run of Shift-arrow presses to settle before showing the bar.
        let work = DispatchWorkItem { [weak self] in self?.showFormatBarIfNeeded() }
        formatWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (NSEvent.pressedMouseButtons == 0 ? 0.25 : 0.05), execute: work)
    }

    func mouseUp() {
        formatWork?.cancel()
        showFormatBarIfNeeded(byMouse: true)
    }

    func hideAll() {
        formatWork?.cancel()
        hideFormatBar(); closeSlash(); hideCodeTools()
    }

    // MARK: Format bar

    /// Selected by the mouse: only then do the AI buttons show, so selecting with the keyboard stays quiet.
    private func showFormatBarIfNeeded(byMouse: Bool = false) {
        guard let editor, editor.isEditable, !editor.hasMarkedText(), editor.window != nil,
              editor.selectedRanges.count == 1, NSEvent.pressedMouseButtons == 0 else { return }
        let selection = editor.selectedRange()
        guard selection.length > 0, NSMaxRange(selection) <= (editor.string as NSString).length else { return }
        let text = editor.string
        let selected = (text as NSString).substring(with: selection)
        let formats = editor.markdownEditing && !MarkdownEditing.inFence(text, at: selection.location)
        let asks = byMouse && editor.selectionAI != nil && SelectionAIButtons.worthShowing(selected)
        guard formats || asks else { return }
        formatTarget = (selection, selected, revision)
        let state = formats ? MarkdownCommands.formatState(text: text, selection: selection) : nil
        let ai = asks ? SelectionAIButtons(agentTitle: editor.agentTitle(), explains: !editor.markdownEditing) { [weak self] action in
            self?.performAI(action)
        } : nil
        let view = MarkdownFormatBar(state: state, ai: ai) { [weak self] action in self?.perform(action) }
        let host = host(&formatHost, view)
        guard let rect = editor.rect(for: selection) else { return }
        let size = host.fittingSize
        let visible = editor.visibleRect
        var y = rect.minY - size.height - 6
        if y < visible.minY + 2 { y = rect.maxY + 6 }
        let x = min(max(visible.minX + 4, rect.minX), visible.maxX - size.width - 4)
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        host.isHidden = false
    }

    private func hideFormatBar() { formatHost?.isHidden = true; formatTarget = nil }

    private func performAI(_ action: EditorSelectionAction) {
        guard let editor, let target = formatTarget, target.revision == revision, editor.selectedRange() == target.selection,
              let selectionAI = editor.selectionAI else { hideFormatBar(); return }
        hideFormatBar()
        selectionAI(action, target.selection)
    }

    private func perform(_ action: MarkdownFormatAction) {
        guard let editor, let target = formatTarget, target.revision == revision,
              editor.selectedRange() == target.selection,
              NSMaxRange(target.selection) <= (editor.string as NSString).length,
              (editor.string as NSString).substring(with: target.selection) == target.text else { hideFormatBar(); return }
        let text = editor.string
        let edit: EditorLineEdit?
        let name: String
        switch action {
        case .bold: edit = MarkdownEditing.toggleWrap(text: text, selection: target.selection, marker: "**"); name = "粗体"
        case .italic: edit = MarkdownEditing.toggleWrap(text: text, selection: target.selection, marker: "*"); name = "斜体"
        case .strike: edit = MarkdownEditing.toggleWrap(text: text, selection: target.selection, marker: "~~"); name = "删除线"
        case .code: edit = MarkdownEditing.toggleWrap(text: text, selection: target.selection, marker: "`"); name = "行内代码"
        case .link: edit = MarkdownEditing.link(text: text, selection: target.selection); name = "链接"
        case .heading(let level): edit = MarkdownCommands.heading(text: text, selection: target.selection, level: level); name = level == 0 ? "正文" : "标题 \(level)"
        }
        editor.window?.makeFirstResponder(editor)
        if let edit { editor.applyMarkdown(edit, name: name) }
        // Keep the bar for further styling of the same (re-selected) text.
        if editor.selectedRange().length > 0 { showFormatBarIfNeeded() }
    }

    // MARK: `/` menu

    /// After typing `/` or `、`: opens the menu when it is a trigger here.
    func typedTrigger() {
        guard let editor, editor.markdownEditing, !editor.hasMarkedText(),
              let trigger = MarkdownCommands.slashTrigger(text: editor.string, selection: editor.selectedRange()),
              trigger.query.isEmpty else { return }
        dismissedTrigger = nil
        slashTrigger = trigger.range
        slashSelected = 0
        updateSlash(query: "")
    }

    private func refreshSlash() {
        guard let editor, let open = slashTrigger else { return }
        // While a pinyin composition is going on its letters are in the text; wait for it to settle.
        if editor.hasMarkedText() {
            if let trigger = MarkdownCommands.slashTrigger(text: editor.string, selection: NSRange(location: editor.selectedRange().location, length: 0)),
               trigger.range.location == open.location {
                slashTrigger = trigger.range; updateSlash(query: trigger.query)
            }
            return
        }
        guard let trigger = MarkdownCommands.slashTrigger(text: editor.string, selection: editor.selectedRange()),
              trigger.range.location == open.location, dismissedTrigger != trigger.range.location else { closeSlash(); return }
        slashTrigger = trigger.range
        updateSlash(query: trigger.query)
    }

    private func updateSlash(query: String) {
        let matches = MarkdownCommands.slashMatches(query)
        if matches.map(\.id) != slashMatches.map(\.id) { slashSelected = 0 }
        slashMatches = matches
        slashSelected = min(slashSelected, max(0, matches.count - 1))
        renderSlash()
    }

    private func renderSlash() {
        guard let editor, let trigger = slashTrigger else { return }
        let matches = slashMatches
        let view = MarkdownSlashMenu(commands: matches, selected: slashSelected) { [weak self] index in self?.pickSlash(index) }
        let host = host(&slashHost, view)
        guard let rect = editor.rect(for: trigger) else { return }
        let rows = CGFloat(max(1, min(MarkdownSlashMenu.visibleRows, matches.count)))
        let height = matches.isEmpty ? 40 : rows * MarkdownSlashMenu.rowHeight + 8
        let visible = editor.visibleRect
        var y = rect.maxY + 4
        if y + height > visible.maxY - 2, rect.minY - height - 4 > visible.minY { y = rect.minY - height - 4 }
        let x = min(max(visible.minX + 4, rect.minX - 6), visible.maxX - 252)
        host.frame = NSRect(x: x, y: y, width: 248, height: height)
        host.isHidden = false
    }

    func closeSlash() {
        slashTrigger = nil; slashMatches = []; slashSelected = 0
        slashHost?.isHidden = true
    }

    /// Esc: the typed text stays; the menu does not come back for this `/`.
    func dismissSlash() {
        dismissedTrigger = slashTrigger?.location
        closeSlash()
    }

    func moveSlashSelection(_ delta: Int) {
        guard !slashMatches.isEmpty else { return }
        slashSelected = (slashSelected + delta + slashMatches.count) % slashMatches.count
        renderSlash()
    }

    /// Return / Tab. False when there is nothing to pick, so the key does what it normally does.
    func pickSelectedSlash() -> Bool {
        guard isSlashOpen else { return false }
        guard slashMatches.indices.contains(slashSelected) else { closeSlash(); return false }
        pickSlash(slashSelected)
        return true
    }

    private func pickSlash(_ index: Int) {
        guard let editor, let trigger = slashTrigger, slashMatches.indices.contains(index) else { return }
        let command = slashMatches[index]
        let text = editor.string
        closeSlash()
        editor.window?.makeFirstResponder(editor)
        if command.action == .image { chooseImage(trigger: trigger, text: text); return }
        guard let edit = MarkdownCommands.slashEdit(command.action, text: text, trigger: trigger) else { return }
        editor.applyMarkdown(edit, name: command.title)
        if command.action == .wiki {
            DispatchQueue.main.async { [weak editor] in editor?.complete(nil) }
        }
    }

    private func chooseImage(trigger: NSRange, text: String) {
        guard let editor, let window = editor.window, let importImages = editor.importImages else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "选择要插入的图片；项目外的图片会复制到 assets/"
        let revision = self.revision
        panel.beginSheetModal(for: window) { [weak self, weak editor] response in
            MainActor.assumeIsolated {
                // Cancel keeps what was typed; a changed document is not edited blind.
                guard response == .OK, let self, let editor, self.revision == revision, editor.string == text,
                      let markdown = importImages(panel.urls, nil) else { return }
                editor.applyMarkdown(MarkdownCommands.imageEdit(markdown, text: text, trigger: trigger), name: "插入图片")
            }
        }
    }

    // MARK: Code tools

    func refreshCodeTools() {
        guard let editor, editor.markdownEditing, !editor.hasMarkedText(), let blocks = fencedBlocks?() else { hideCodeTools(); return }
        let caret = editor.selectedRange().location
        let source = editor.string as NSString
        guard let block = blocks.first(where: { caret >= $0.location && caret <= NSMaxRange($0) }),
              NSMaxRange(block) <= source.length else { hideCodeTools(); return }
        let blockText = source.substring(with: block)
        guard var found = MarkdownCommands.fence(in: blockText, at: 0) else { hideCodeTools(); return }
        func shift(_ range: NSRange) -> NSRange { NSRange(location: range.location + block.location, length: range.length) }
        found = MarkdownCommands.Fence(range: shift(found.range), opening: shift(found.opening), content: shift(found.content),
                                       language: found.language, languageRange: shift(found.languageRange))
        if fence?.range.location != found.range.location { copiedFence = nil }
        fence = found
        showCodeTools()
    }

    private func showCodeTools() {
        guard let editor, let fence else { return }
        let view = MarkdownCodeTools(language: fence.language, copied: copiedFence == fence.range.location,
                                     setLanguage: { [weak self] in self?.setLanguage($0) },
                                     copy: { [weak self] in self?.copyCode() })
        let host = host(&codeHost, view)
        guard let line = editor.rect(for: fence.opening.length > 0 ? fence.opening : NSRange(location: fence.opening.location, length: 0)) else { return }
        let size = host.fittingSize
        let visible = editor.visibleRect
        let right = editor.textContainerOrigin.x + (editor.textContainer?.size.width ?? visible.width) - 4
        let x = min(visible.maxX - size.width - 8, right - size.width)
        host.frame = NSRect(x: max(visible.minX + 4, x), y: line.minY + (line.height - size.height) / 2, width: size.width, height: size.height)
        host.isHidden = false
    }

    private func hideCodeTools() { codeHost?.isHidden = true; fence = nil }

    private func copyCode() {
        guard let editor, let fence, NSMaxRange(fence.range) <= (editor.string as NSString).length else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MarkdownCommands.code(of: fence, in: editor.string), forType: .string)
        copiedFence = fence.range.location
        showCodeTools()
        let location = fence.range.location
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.copiedFence == location else { return }
            self.copiedFence = nil
            if self.fence != nil { self.showCodeTools() }
        }
    }

    private func setLanguage(_ language: String) {
        guard let editor, let fence, fence.language != language else { return }
        let edit = MarkdownCommands.setLanguage(language, of: fence, text: editor.string)
        let caret = editor.selectedRange()
        let delta = (edit.replacement as NSString).length - edit.range.length
        let moved = caret.location >= NSMaxRange(edit.range) ? NSRange(location: caret.location + delta, length: caret.length) : caret
        editor.window?.makeFirstResponder(editor)
        editor.applyMarkdown(EditorLineEdit(range: edit.range, replacement: edit.replacement, selection: moved), name: "代码语言")
    }

    // MARK: Hosting

    private func host<V: View>(_ slot: inout NSHostingView<AnyView>?, _ view: V) -> NSHostingView<AnyView> {
        let (theme, glass) = style?() ?? (.standard, true)
        let root = AnyView(view.environment(\.folmiTheme, theme).environment(\.folmiGlass, glass)
            .tint(Color.theme(theme, \.accent)))
        if let existing = slot {
            existing.rootView = root
            if existing.superview !== editor, let editor { editor.addSubview(existing) }
            return existing
        }
        let created = OverlayHostingView(rootView: root)
        created.isHidden = true
        editor?.addSubview(created)
        slot = created
        return created
    }
}

/// The floating controls inside a text view: an arrow over them, not the text view's I-beam.
final class OverlayHostingView: NSHostingView<AnyView> {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}

extension EditorTextView {
    /// The view rectangle of a character range's first line fragment run, or nil before layout.
    func rect(for range: NSRange) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer, range.location <= (textStorage?.length ?? 0) else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs.length > 0 ? glyphs : NSRange(location: glyphs.location, length: 0), in: container)
        if glyphs.length == 0 {
            // An empty range: the caret's line.
            let index = min(glyphs.location, max(0, layout.numberOfGlyphs - 1))
            if layout.numberOfGlyphs > 0 {
                let fragment = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: nil)
                rect = NSRect(x: layout.location(forGlyphAt: index).x + fragment.minX, y: fragment.minY, width: 1, height: fragment.height)
            } else {
                rect = layout.extraLineFragmentRect
            }
        }
        let origin = textContainerOrigin
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }
}
