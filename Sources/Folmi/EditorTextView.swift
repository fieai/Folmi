import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit
import Darwin
import FolmiCore

final class FindPanelSender: NSObject {
    @objc var tag: Int { Int(NSTextFinder.Action.showReplaceInterface.rawValue) }
}

/// Edits remain normal AppKit text transactions, including native undo and input-method composition.
class EditorTextView: NSTextView {
    var tabSize = 2
    var toggleMarkdown: (() -> Void)?
    /// List continuation, list indent, formatting shortcuts and bracket pairs for Markdown files.
    var markdownEditing = false
    /// ⌘-click on a Markdown link hands its target here.
    var openLink: ((String) -> Void)?
    /// Pastes the selected lines, with their file and line numbers, into the terminal.
    var sendSelection: ((NSRange) -> Void)?
    /// Set for JavaScript, TypeScript and Python files: 查看调用关系 for the name at a position.
    var showCalls: ((Int) -> Void)?
    var assistSelection: ((AIAssistState.Mode, String) -> Void)?
    /// Pasted or dropped image files, or a pasted picture, turned into Markdown to insert.
    var importImages: ((_ files: [URL], _ png: Data?) -> String?)?
    /// The project file an image address names, for 查看原图 / 在 Finder 中显示; nil when there is none.
    var imageFile: ((String) -> URL?)?
    /// The link a chosen image file gets from this document (copied into assets/ when it is outside the project).
    var imageLink: ((URL) -> String?)?
    /// Note names offered after `[[`.
    var wikiCompletions: ((String) -> [String])?
    /// A short message for the user, such as what a rich-text paste could not keep.
    var onNotice: ((String) -> Void)?
    /// The format bar, the `/` menu and the code-block tools.
    lazy var overlays: MarkdownOverlays = {
        let overlays = MarkdownOverlays()
        overlays.editor = self
        return overlays
    }()

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if markdownEditing { overlays.selectionChanged(stillSelecting: stillSelecting) }
    }
    override func didChangeText() {
        super.didChangeText()
        if markdownEditing { overlays.textChanged() }
    }

    // MARK: Note after the caret's line (who last changed it)

    /// The line's character range and the note's text. Drawn after the text, never part of it, so copying, search
    /// and undo never see it.
    struct LineNote: Equatable {
        let range: NSRange
        let text: String
        /// Whether hovering or clicking it opens a card (only notes about a commit do).
        let opens: Bool
    }
    var blameNote: LineNote? {
        didSet {
            guard blameNote != oldValue else { return }
            if let old = blameNoteRect { setNeedsDisplay(old.insetBy(dx: -2, dy: -2)) }
            blameNoteRect = nil
            if let rect = blameNoteGeometry()?.rect { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
        }
    }
    /// Where the note was last drawn, for hover and clicks.
    private(set) var blameNoteRect: NSRect?
    /// Hovering or clicking a note that `opens` shows its card.
    var openBlameNote: ((NSRect) -> Void)?
    var focusChanged: ((Bool) -> Void)?
    private var hoverWork: DispatchWorkItem?
    private var noteTracking: NSTrackingArea?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusChanged?(false) }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let geometry = blameNoteGeometry() else { blameNoteRect = nil; return }
        blameNoteRect = geometry.rect
        if geometry.rect.intersects(dirtyRect) {
            (geometry.text as NSString).draw(at: geometry.rect.origin, withAttributes: geometry.attributes)
        }
    }

    private func blameNoteGeometry() -> (rect: NSRect, text: String, attributes: [NSAttributedString.Key: Any])? {
        guard let note = blameNote, !note.text.isEmpty, let layout = layoutManager, let container = textContainer else { return nil }
        let text = string as NSString
        guard NSMaxRange(note.range) <= text.length, note.range.location < text.length else { return nil }
        var end = NSMaxRange(note.range)
        while end > note.range.location, [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: note.range.location, length: end - note.range.location), actualCharacterRange: nil)
        let glyph = glyphs.length > 0 ? NSMaxRange(glyphs) - 1 : layout.glyphIndexForCharacter(at: note.range.location)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = textContainerOrigin
        let base = font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let noteFont = NSFontManager.shared.convert(base, toSize: max(9, base.pointSize - 1))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: noteFont, .foregroundColor: (textColor ?? .textColor).withAlphaComponent(0.38)
        ]
        let x = origin.x + (glyphs.length > 0 ? used.maxX : fragment.minX) + max(24, base.pointSize * 2)
        // Wrapped text ends at the container's edge; unwrapped text leaves a bounded strip after the line.
        let right = container.widthTracksTextView ? origin.x + container.size.width : x + 520
        let available = right - x
        guard available >= 80 else { return nil }
        let shown = Self.truncated(note.text, width: available, attributes: attributes)
        guard let shown else { return nil }
        let size = (shown as NSString).size(withAttributes: attributes)
        let baseline = origin.y + fragment.minY + layout.location(forGlyphAt: glyph).y
        let rect = NSRect(x: x, y: baseline - noteFont.ascender, width: ceil(size.width), height: ceil(size.height))
        return (rect, shown, attributes)
    }

    /// The text cut at the end with "…" to fit; nil when not even a few characters fit.
    static func truncated(_ text: String, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String? {
        if (text as NSString).size(withAttributes: attributes).width <= width { return text }
        let characters = Array(text)
        var low = 0, high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if (String(characters[..<middle]) + "…" as NSString).size(withAttributes: attributes).width <= width { low = middle } else { high = middle - 1 }
        }
        return low >= 4 ? String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…" : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let noteTracking { removeTrackingArea(noteTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        noteTracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let rect = blameNoteRect, blameNote?.opens == true, openBlameNote != nil, rect.contains(convert(event.locationInWindow, from: nil)) else {
            hoverWork?.cancel(); hoverWork = nil; return
        }
        NSCursor.pointingHand.set()
        guard hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            guard let rect = self.blameNoteRect, let window = self.window,
                  rect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
            self.openBlameNote?(rect)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if markdownEditing { overlays.textChanged() }
    }
    override func moveUp(_ sender: Any?) {
        if markdownEditing, overlays.isSlashOpen, !hasMarkedText() { overlays.moveSlashSelection(-1); return }
        super.moveUp(sender)
    }
    override func moveDown(_ sender: Any?) {
        if markdownEditing, overlays.isSlashOpen, !hasMarkedText() { overlays.moveSlashSelection(1); return }
        super.moveDown(sender)
    }
    override func cancelOperation(_ sender: Any?) {
        if markdownEditing, overlays.isSlashOpen { overlays.dismissSlash(); return }
        if markdownEditing, overlays.isFormatBarShown { overlays.hideAll(); return }
        super.cancelOperation(sender)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { overlays.hideAll() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Right-click in a table or a code block adds its commands above the usual ones.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let showCalls {
            let location = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            let entry = MarkdownMenuItem(title: "查看调用关系") { showCalls(location) }
            entry.keyEquivalent = "h"; entry.keyEquivalentModifierMask = [.control, .option]
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(entry, at: 0)
        }
        if let sendSelection {
            let range = selectedRange()
            let entry = MarkdownMenuItem(title: range.length > 0 ? "发送选中的行到终端" : "发送这一行到终端") { sendSelection(range) }
            entry.keyEquivalent = "l"; entry.keyEquivalentModifierMask = [.command, .option]
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(entry, at: 0)
        }
        if let assistSelection, selectedRange().length > 0 {
            let text = (string as NSString).substring(with: selectedRange())
            let translate = MarkdownMenuItem(title: "翻译") { assistSelection(.translate, text) }
            translate.keyEquivalent = "t"; translate.keyEquivalentModifierMask = [.command, .control]
            menu.insertItem(translate, at: 0)
            menu.insertItem(MarkdownMenuItem(title: "去 AI 腔") { assistSelection(.deAI, text) }, at: 0)
            menu.insertItem(MarkdownMenuItem(title: "说人话") { assistSelection(.plain, text) }, at: 0)
        }
        guard markdownEditing, isEditable, !hasMarkedText() else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        let location = characterIndexForInsertion(at: point)
        var items: [NSMenuItem] = imageMenuItems(at: point, location: location)
        func item(_ title: String, _ make: @escaping (String, Int) -> EditorLineEdit?, name: String) -> NSMenuItem {
            let entry = MarkdownMenuItem(title: title) { [weak self] in
                guard let self, let edit = make(self.string, location) else { NSSound.beep(); return }
                self.applyMarkdown(edit, name: name)
            }
            return entry
        }
        if MarkdownTable.table(in: string, at: location) != nil {
            items += [
                item("在上方插入行", { MarkdownTable.insertRow(text: $0, at: $1, .above) }, name: "插入行"),
                item("在下方插入行", { MarkdownTable.insertRow(text: $0, at: $1, .below) }, name: "插入行"),
                item("在左侧插入列", { MarkdownTable.insertColumn(text: $0, at: $1, .left) }, name: "插入列"),
                item("在右侧插入列", { MarkdownTable.insertColumn(text: $0, at: $1, .right) }, name: "插入列"),
                .separator(),
                item("删除这一行", { MarkdownTable.deleteRow(text: $0, at: $1) }, name: "删除行"),
                item("删除这一列", { MarkdownTable.deleteColumn(text: $0, at: $1) }, name: "删除列"),
                .separator(),
                item("这一列左对齐", { MarkdownTable.align(text: $0, at: $1, .left) }, name: "对齐"),
                item("这一列居中", { MarkdownTable.align(text: $0, at: $1, .center) }, name: "对齐"),
                item("这一列右对齐", { MarkdownTable.align(text: $0, at: $1, .right) }, name: "对齐"),
                MarkdownMenuItem(title: "复制表格源码") { [weak self] in
                    guard let self, let source = MarkdownTable.source(text: self.string, at: location) else { return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string)
                },
            ]
            if let header = MarkdownTable.table(in: string, at: location)?.rows.first?.line, NSLocationInRange(location, header) || location == NSMaxRange(header) {
                // The header row cannot go: say so instead of offering it.
                items[5].isEnabled = false
                items[5].toolTip = "表头行不能删除；可以删除整张表的源码。"
            }
        }
        if let fence = MarkdownCommands.fence(in: string, at: location) {
            items.append(MarkdownMenuItem(title: "复制代码") { [weak self] in
                guard let self, NSMaxRange(fence.range) <= (self.string as NSString).length else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MarkdownCommands.code(of: fence, in: self.string), forType: .string)
            })
        }
        guard !items.isEmpty else { return menu }
        items.append(.separator())
        for (index, entry) in items.enumerated() { menu.insertItem(entry, at: index) }
        return menu
    }

    /// 查看原图 / 在 Finder 中显示 / 替换图片 / 复制图片地址, for a picture under the pointer or an image line at `location`.
    private func imageMenuItems(at point: NSPoint, location: Int) -> [NSMenuItem] {
        let source = string as NSString
        guard location <= source.length else { return [] }
        let line = source.lineRange(for: NSRange(location: min(location, source.length), length: 0))
        guard let targetRange = MarkdownImageSource.targetRange(in: string, line: line) else { return [] }
        let target = source.substring(with: targetRange)
        let file = imageFile?(target)
        let view = MarkdownMenuItem(title: "查看原图") { if let file { NSWorkspace.shared.open(file) } }
        view.isEnabled = file != nil
        let reveal = MarkdownMenuItem(title: "在 Finder 中显示") { if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
        reveal.isEnabled = file != nil
        if file == nil { view.toolTip = "只能打开项目里存在的图片文件。"; reveal.toolTip = view.toolTip }
        let replace = MarkdownMenuItem(title: "替换图片…") { [weak self] in self?.replaceImage(target: target, at: targetRange) }
        replace.isEnabled = imageLink != nil
        let copy = MarkdownMenuItem(title: "复制图片地址") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(target, forType: .string)
        }
        return [view, reveal, replace, copy, .separator()]
    }

    /// Picks an image file and swaps only the address; alt text and title stay. One undo step.
    private func replaceImage(target: String, at range: NSRange) {
        guard let imageLink, let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = EditorWorkspace.imageExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "选择新图片。项目外的文件会复制到文档旁的 assets/。"
        if let current = imageFile?(target) { panel.directoryURL = current.deletingLastPathComponent() }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            // The document may have changed while the panel was open; only replace the address if it is still there.
            guard NSMaxRange(range) <= (self.string as NSString).length,
                  (self.string as NSString).substring(with: range) == target, let link = imageLink(url) else { NSSound.beep(); return }
            self.applyMarkdown(EditorLineEdit(range: range, replacement: link, selection: self.selectedRange()), name: "替换图片")
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let rect = blameNoteRect, blameNote?.opens == true, event.clickCount == 1,
           rect.contains(convert(event.locationInWindow, from: nil)), let openBlameNote {
            hoverWork?.cancel()
            openBlameNote(rect)
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if markdownEditing, !hasMarkedText(), event.clickCount == 1 {
            let point = convert(event.locationInWindow, from: nil)
            if modifiers == .command, let openLink, let index = characterIndex(at: point),
               let target = MarkdownLinks.target(in: string, at: index) {
                openLink(target)
                return
            }
        }
        super.mouseDown(with: event)
        // NSTextView tracks the drag until the button is released, so the selection is final here.
        if markdownEditing { overlays.mouseUp() }
    }
    /// The character under a point in view coordinates, or nil past the end of its line.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, (textStorage?.length ?? 0) > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -2, dy: 0).contains(local) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let isFindKey = event.keyCode == 3 || key == "f"
        if markdownEditing, isEditable, !hasMarkedText(), window?.firstResponder === self, let key,
           let edit = markdownShortcut(key: key, keyCode: event.keyCode, modifiers: modifiers) {
            applyMarkdown(edit.edit, name: edit.name)
            return true
        }
        if modifiers == .command, key == "d", !hasMarkedText() { applyLineCommand(duplicate: false); return true }
        if modifiers == [.command, .option], event.keyCode == 125, !hasMarkedText() { applyLineCommand(duplicate: true); return true }
        if modifiers == [.shift, .option], event.keyCode == 46, let toggleMarkdown { toggleMarkdown(); return true }
        if isFindKey, modifiers == .command || modifiers == [.command, .option] {
            let sender = NSMenuItem()
            sender.tag = Int(event.modifierFlags.contains(.option)
                ? NSTextFinder.Action.showReplaceInterface.rawValue : NSTextFinder.Action.showFindInterface.rawValue)
            performTextFinderAction(sender)
            return true
        }
        // Project search (Cmd+Shift+F) and system shortcuts belong to the menu responder chain.
        if isFindKey, modifiers.contains(.command) { return false }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if modifiers == [.shift, .option], event.keyCode == 46, let toggleMarkdown {
            toggleMarkdown(); return
        }
        super.keyDown(with: event)
    }
    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertTab(sender); return }
        if markdownEditing, overlays.pickSelectedSlash() { return }
        if markdownEditing, let edit = MarkdownTable.tab(text: string, selection: selectedRange(), backward: false) {
            applyMarkdown(edit, name: "表格"); return
        }
        if markdownEditing, let edit = MarkdownEditing.indent(text: string, selection: selectedRange(), outdent: false, tabSize: tabSize) {
            applyMarkdown(edit, name: "缩进列表"); return
        }
        insertText(String(repeating: " ", count: min(8, max(1, tabSize))), replacementRange: selectedRange())
    }
    override func insertBacktab(_ sender: Any?) {
        if !hasMarkedText(), markdownEditing, let edit = MarkdownTable.tab(text: string, selection: selectedRange(), backward: true) {
            applyMarkdown(edit, name: "表格"); return
        }
        guard !hasMarkedText(), markdownEditing,
              let edit = MarkdownEditing.indent(text: string, selection: selectedRange(), outdent: true, tabSize: tabSize) else {
            super.insertBacktab(sender); return
        }
        applyMarkdown(edit, name: "减少列表缩进")
    }
    override func insertText(_ text: Any, replacementRange: NSRange) {
        // Only a single typed character outside input-method composition; pastes and composed text go in as they are.
        let typed = (text as? String) ?? (text as? NSAttributedString)?.string
        if markdownEditing, !hasMarkedText(), replacementRange.location == NSNotFound,
           let typed, typed.count == 1, let character = typed.first,
           let edit = MarkdownEditing.typed(character, text: string, selection: selectedRange()) {
            applyMarkdown(edit, name: "输入")
        } else {
            super.insertText(text, replacementRange: replacementRange)
        }
        if markdownEditing, typed == "/" || typed == "、" { overlays.typedTrigger() }
        // Typing a name after `[[` keeps the note list open and narrowing.
        if markdownEditing, wikiCompletions != nil, typed?.count == 1, !hasMarkedText(),
           MarkdownWiki.partialRange(text: string, selection: selectedRange()) != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasMarkedText(), self.window?.firstResponder === self,
                      MarkdownWiki.partialRange(text: self.string, selection: self.selectedRange()) != nil else { return }
                self.complete(nil)
            }
        }
    }
    override var rangeForUserCompletion: NSRange {
        if markdownEditing, wikiCompletions != nil, let range = MarkdownWiki.partialRange(text: string, selection: selectedRange()) { return range }
        return super.rangeForUserCompletion
    }
    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        if markdownEditing, let wikiCompletions, let range = MarkdownWiki.partialRange(text: string, selection: selectedRange()), range == charRange {
            let names = wikiCompletions((string as NSString).substring(with: range))
            // Nothing is inserted until a name is picked.
            index.pointee = -1
            return names.isEmpty ? nil : names
        }
        return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
    }
    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        // A picked name steps over the closing brackets.
        guard markdownEditing, flag, movement != NSTextMovement.cancel.rawValue, movement != NSTextMovement.other.rawValue else { return }
        let source = string as NSString, caret = selectedRange()
        if caret.length == 0, caret.location + 2 <= source.length, source.substring(with: NSRange(location: caret.location, length: 2)) == "]]",
           caret.location >= 2, source.substring(to: caret.location).range(of: "[[", options: .backwards) != nil {
            setSelectedRange(NSRange(location: caret.location + 2, length: 0))
        }
    }
    override func deleteBackward(_ sender: Any?) {
        if markdownEditing, !hasMarkedText(), let edit = MarkdownEditing.deleteBackward(text: string, selection: selectedRange()) {
            applyMarkdown(edit, name: "删除"); return
        }
        super.deleteBackward(sender)
    }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        if markdownEditing, overlays.pickSelectedSlash() { return }
        if markdownEditing, let edit = MarkdownEditing.newline(text: string, selection: EditorTextPosition.clamp(selectedRange(), in: string), tabSize: tabSize) {
            applyMarkdown(edit, name: "换行"); return
        }
        let source = string as NSString
        let selection = EditorTextPosition.clamp(selectedRange(), in: string)
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefix = source.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
        let extra = prefix.trimmingCharacters(in: .whitespaces).last.map { "{[:".contains($0) } == true
            ? String(repeating: " ", count: min(8, max(1, tabSize))) : ""
        insertText("\n" + indent + extra, replacementRange: selection)
    }
    private func markdownShortcut(key: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> (edit: EditorLineEdit, name: String)? {
        let text = string, selection = EditorTextPosition.clamp(selectedRange(), in: string)
        switch (modifiers, key) {
        case (.command, "b"): return (MarkdownEditing.toggleWrap(text: text, selection: selection, marker: "**"), "粗体")
        case (.command, "i"): return (MarkdownEditing.toggleWrap(text: text, selection: selection, marker: "*"), "斜体")
        case (.command, "e"): return (MarkdownEditing.toggleWrap(text: text, selection: selection, marker: "`"), "行内代码")
        case ([.command, .shift], "x"): return (MarkdownEditing.toggleWrap(text: text, selection: selection, marker: "~~"), "删除线")
        // ⇧⌘K, not ⌘K: ⌘K is the app-wide search and must reach it from every focus.
        case ([.command, .shift], "k"): return (MarkdownEditing.link(text: text, selection: selection), "链接")
        default: break
        }
        // ⌥⌘T by key code, since Option changes the typed character.
        if modifiers == [.command, .option], keyCode == 17 {
            return (MarkdownTable.insert(text: text, selection: selection), "插入表格")
        }
        // ⌥⌘0…6 by key code, since Option changes the typed character.
        let digits: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6]
        if modifiers == [.command, .option], let level = digits[keyCode],
           let edit = MarkdownEditing.heading(text: text, selection: selection, level: level) {
            return (edit, level == 0 ? "正文" : "标题 \(level)")
        }
        return nil
    }
    override func paste(_ sender: Any?) {
        if markdownEditing, isEditable, !hasMarkedText(), insertImages(from: .general) { return }
        if markdownEditing, isEditable, !hasMarkedText(), pasteRichText(from: .general) { return }
        super.paste(sender)
    }
    /// Rich text (a web page, Feishu, Google Docs) pasted as Markdown, in one undo step. False leaves it to the plain
    /// text paste: inside code, for text without structure, or past the conversion budget.
    func pasteRichText(from pasteboard: NSPasteboard) -> Bool {
        guard let html = pasteboard.string(forType: .html) ?? pasteboard.data(forType: .html).flatMap({ String(data: $0, encoding: .utf8) }),
              !html.isEmpty else { return false }
        let selection = EditorTextPosition.clamp(selectedRange(), in: string)
        guard !MarkdownEditing.inFence(string, at: selection.location) else { return false }
        guard html.utf8.count <= MarkdownPaste.maximumBytes else { onNotice?("富文本超过 1 MiB，已按纯文本粘贴"); return false }
        guard let result = MarkdownPaste.markdown(fromHTML: html) else { return false }
        insertText(result.markdown, replacementRange: selection)
        undoManager?.setActionName("粘贴为 Markdown")
        onNotice?(result.notes.isEmpty ? "已按 Markdown 粘贴；只要纯文本可用 ⌥⇧⌘V" : "已按 Markdown 粘贴：" + result.notes.joined(separator: "；"))
        return true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if markdownEditing, isEditable, !hasMarkedText(), !sender.draggingPasteboard.markdownImageFiles.isEmpty {
            let point = convert(sender.draggingLocation, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            if insertImages(from: sender.draggingPasteboard) { return true }
        }
        return super.performDragOperation(sender)
    }
    /// Pasted image files or a pasted picture become image links on their own line. False when there is none.
    func insertImages(from pasteboard: NSPasteboard) -> Bool {
        let files = pasteboard.markdownImageFiles
        let png = files.isEmpty ? pasteboard.markdownImagePNG : nil
        guard let importImages, !files.isEmpty || png != nil else { return false }
        guard var markdown = importImages(files, png) else { return true }
        let source = string as NSString
        let selection = EditorTextPosition.clamp(selectedRange(), in: string)
        if selection.location > 0, ![10, 13].contains(source.character(at: selection.location - 1)) { markdown = "\n" + markdown }
        if NSMaxRange(selection) < source.length, ![10, 13].contains(source.character(at: NSMaxRange(selection))) { markdown += "\n" }
        insertText(markdown, replacementRange: selection)
        undoManager?.setActionName("插入图片")
        return true
    }
    /// Applies a Markdown command as one undoable edit; an empty edit only moves the caret.
    func applyMarkdown(_ edit: EditorLineEdit, name: String) {
        guard isEditable else { return }
        if edit.range.length == 0, edit.replacement.isEmpty { setSelectedRange(EditorTextPosition.clamp(edit.selection, in: string)); return }
        // A command is its own undo step, never merged into the typing before it.
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(EditorTextPosition.clamp(edit.selection, in: string))
        undoManager?.setActionName(name)
        breakUndoCoalescing()
    }
    func applyLineCommand(duplicate: Bool) {
        guard isEditable, !hasMarkedText(), let edit = EditorLineEdit.make(text: string, selection: selectedRange(), duplicate: duplicate),
              shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(EditorTextPosition.clamp(edit.selection, in: string))
        undoManager?.setActionName(duplicate ? "复制行" : "删除行")
    }
}

/// A context-menu item that runs a closure.
final class MarkdownMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}

struct EditorLineEdit {
    let range: NSRange
    let replacement: String
    let selection: NSRange
    static func make(text: String, selection: NSRange, duplicate: Bool) -> EditorLineEdit? {
        let source = text as NSString
        guard source.length > 0 else { return nil }
        let chosen = EditorTextPosition.clamp(selection, in: text)
        let end = chosen.length > 0 ? NSMaxRange(chosen) - 1 : chosen.location
        let startLine = source.lineRange(for: NSRange(location: chosen.location, length: 0))
        let endLine = source.lineRange(for: NSRange(location: end, length: 0))
        var lines = NSRange(location: startLine.location, length: NSMaxRange(endLine) - startLine.location)
        if !duplicate {
            if lines.length == 0, lines.location > 0 { lines = NSRange(location: lines.location - 1, length: 1) }
            return EditorLineEdit(range: lines, replacement: "", selection: NSRange(location: lines.location, length: 0))
        }
        let content = source.substring(with: lines)
        guard !content.isEmpty else { return nil }
        let endsInNewline = content.hasSuffix("\n") || content.hasSuffix("\r")
        let insertion = endsInNewline ? content : "\n" + content
        let caretOffset = chosen.location - lines.location
        let location = NSMaxRange(lines) + (endsInNewline ? 0 : 1) + caretOffset
        return EditorLineEdit(range: NSRange(location: NSMaxRange(lines), length: 0), replacement: insertion,
                              selection: NSRange(location: location, length: chosen.length))
    }
}
