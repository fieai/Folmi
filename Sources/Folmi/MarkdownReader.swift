import AppKit
import FolmiCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The Markdown reading view: the document rendered by `MarkdownHTML` in a WKWebView. Script in the page is ours only
/// (the renderer escapes raw HTML); it reports clicks and selections back, and every change to the file goes through
/// the workspace, the same as the source editor.
struct MarkdownReaderView: NSViewRepresentable {
    let workspace: EditorWorkspace
    let documentID: String
    let text: String
    let presentation: EditorPresentation
    let theme: FolmiTheme
    let navigationRevision: UInt64
    let indexRevision: UInt64
    /// Shown, rather than faded out behind the source editor.
    var active = true
    /// False while a code file is open: the view stays alive but renders nothing.
    var isMarkdown = true
    /// When the file last changed on disk under the reader (an agent edited it); its changed blocks light up.
    var externalChange: Date?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        PerfLog.mark("launch.readerCreated")
        let prepared = ReaderWebViewPool.take() ?? ReaderWebViewPool.make()
        prepared.files.root = workspace.root
        prepared.messages.target = context.coordinator
        let webView = prepared.webView
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView, loaded: prepared.loaded)
        ReaderWebViewPool.refillLater()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        PerfLog.body("MarkdownReaderView.update")
        let start = ContinuousClock.now
        PerfLog.readerStep("reader.updateAt")
        context.coordinator.update(self)
        PerfLog.spend("MarkdownReaderView.update", since: start)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private weak var webView: WKWebView?
        private var parent: MarkdownReaderView?
        private var loaded = false
        private var renderedKey: (documentID: String, text: String, style: String)?
        private var renderTask: Task<Void, Never>?
        private var marksTask: Task<Void, Never>?
        private var navigationRevision: UInt64 = 0
        private var indexRevision: UInt64 = .max
        private var lineStarts: [Int] = [0]
        private var dismantled = false
        private let createdAt = ContinuousClock.now

        func attach(_ webView: WKWebView, loaded: Bool = false) {
            self.webView = webView
            if loaded { self.loaded = true; PerfLog.interval("reader.templateLoad", since: createdAt, detail: "prewarmed") }
        }
        func openFind() {
            guard let webView else { return }
            webView.window?.makeFirstResponder(webView)
            js("wb.find()")
        }
        private func js(_ script: String) { webView?.evaluateJavaScript(script, completionHandler: nil) }

        func update(_ view: MarkdownReaderView) {
            let previous = parent
            parent = view
            view.workspace.openReaderFind = { [weak self] in self?.openFind() }
            updateActive(view)
            guard loaded, view.isMarkdown else { return }
            let style = MarkdownReaderPage.style(theme: view.theme, presentation: view.presentation)
            let documentChanged = renderedKey?.documentID != view.documentID
            if renderedKey?.documentID != view.documentID || renderedKey?.text != view.text || renderedKey?.style != style {
                if renderedKey?.style != style { js("wb.style(\(Self.json(style)))") }
                let flashFrom = !documentChanged && view.externalChange != nil && view.externalChange != flashedChange ? renderedKey?.text : nil
                render(view, scrollTo: documentChanged ? startLine(view) : nil, documentChanged: documentChanged, flashFrom: flashFrom)
                renderedKey = (view.documentID, view.text, style)
            }
            flashedChange = view.externalChange
            if documentChanged || view.indexRevision != indexRevision || previous?.text != view.text {
                indexRevision = view.indexRevision
                loadMarks(view)
            }
            if view.navigationRevision != navigationRevision {
                navigationRevision = view.navigationRevision
                if !documentChanged, let state = view.workspace.tabStates[view.documentID] {
                    scroll(toLine: line(at: state.selectionLocation), smooth: true)
                }
            }
        }

        private var active: Bool?
        private var hideWork: DispatchWorkItem?

        /// Coming forward scrolls to the place the editor was showing and takes keyboard focus; going behind hides
        /// the web view once the fade is over. The page stays loaded either way.
        private func updateActive(_ view: MarkdownReaderView) {
            guard active != view.active else { return }
            let first = active == nil
            active = view.active
            hideWork?.cancel()
            guard let webView else { return }
            if view.active {
                webView.isHidden = false
                guard !first else { return }
                if loaded, let line = view.workspace.readerTopLine[view.documentID] { scroll(toLine: line, smooth: false) }
                DispatchQueue.main.async { [weak webView] in
                    if let webView, webView.window != nil { webView.window?.makeFirstResponder(webView) }
                }
            } else {
                js("document.getElementById('pop').classList.remove('on')")
                // Behind a code file the page stays un-hidden (only transparent and not hit-testable): a hidden web view
                // drops its layers, and showing it again repaints the whole document.
                guard view.isMarkdown else { return }
                let work = DispatchWorkItem { [weak self, weak webView] in
                    guard self?.active == false else { return }
                    webView?.isHidden = true
                }
                hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (first ? 0 : 0.25), execute: work)
            }
        }

        /// Where a document opens: the reader's last place, else the editor caret's line.
        private func startLine(_ view: MarkdownReaderView) -> Int {
            if let line = view.workspace.readerTopLine[view.documentID] { return line }
            let location = view.workspace.tabStates[view.documentID]?.selectionLocation ?? 0
            return Self.lineStarts(view.text).lastIndex { $0 <= location } ?? 0
        }

        private var flashedChange: Date?

        /// `flashFrom`: the text before an outside change; blocks that differ from it light up and fade.
        private func render(_ view: MarkdownReaderView, scrollTo line: Int?, documentChanged: Bool, flashFrom: String? = nil) {
            renderTask?.cancel()
            let text = view.text, path = view.documentID
            let renderStart = ContinuousClock.now
            // A page rendered before (or prefetched) goes to the web view at once. Handing it over from a task put it
            // behind the window's layout pass, about 40 ms on every switch.
            if let cached = ReaderRenderCache.find(path: path, text: text) {
                show(cached, line: line, documentChanged: documentChanged, flashFrom: flashFrom, renderStart: renderStart)
                return
            }
            renderTask = Task { @MainActor [weak self] in
                let rendered = await ReaderRenderCache.render(path: path, text: text, priority: .userInitiated)
                guard let self, !Task.isCancelled, !self.dismantled, self.parent?.documentID == path else { return }
                self.show(rendered, line: line, documentChanged: documentChanged, flashFrom: flashFrom, renderStart: renderStart)
            }
        }

        private func show(_ rendered: ReaderRenderCache.Entry, line: Int?, documentChanged: Bool, flashFrom: String?,
                          renderStart: ContinuousClock.Instant) {
            let (html, path, text) = (rendered.html, rendered.path, rendered.text)
            PerfLog.readerStep("reader.renderAt")
            lineStarts = rendered.starts
            let scroll = line.map(String.init) ?? "null"
            if PerfLog.enabled {
                let swiftDone = ContinuousClock.now
                PerfLog.interval("reader.swift", since: renderStart, detail: path)
                webView?.evaluateJavaScript("(()=>{const t=performance.now();wb.render(\(Self.json(html)), \(scroll), \(documentChanged));const a=performance.now()-t;document.body.offsetHeight;return [a, performance.now()-t]})()") { value, _ in
                    if let pair = value as? [Double] { PerfLog.note("reader.js", "render \(Int(pair[0]))ms layout \(Int(pair[1]))ms \(html.utf8.count)B") }
                    PerfLog.interval("reader.jsRoundtrip", since: swiftDone)
                }
                // Two animation frames after the DOM change: the page has been laid out and painted.
                webView?.callAsyncJavaScript("await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return 0",
                                             arguments: [:], in: nil, in: .page) { _ in
                    PerfLog.readerPainted(path, bytes: text.utf8.count, renderStart: renderStart)
                }
            } else { js("wb.render(\(Self.json(html)), \(scroll), \(documentChanged))") }
            // The outline is published state; this can run inside a view update, so it moves to the next turn.
            let layout = rendered.layout
            renderTask = Task { @MainActor [weak self] in
                if let flashFrom {
                    let ranges = await Task.detached(priority: .utility) {
                        GutterDiff.changes(base: flashFrom, current: text).filter { !$0.new.isEmpty }.map { [$0.new.lowerBound, $0.new.upperBound - 1] }
                    }.value
                    guard let self, !Task.isCancelled, self.parent?.documentID == path else { return }
                    if !ranges.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ranges), let list = String(data: data, encoding: .utf8) {
                        self.js("wb.flash(\(list))")
                    }
                }
                guard let self, !Task.isCancelled, !self.dismantled, let parent = self.parent, parent.documentID == path else { return }
                parent.workspace.outline.update(documentID: path, layout: layout,
                                                caret: self.offset(ofLine: parent.workspace.readerTopLine[path] ?? line ?? 0))
            }
        }

        /// Bars beside blocks that differ from the index (or HEAD for a file with nothing staged), like the editor gutter.
        private func loadMarks(_ view: MarkdownReaderView) {
            marksTask?.cancel()
            let text = view.text, path = view.documentID
            guard let load = view.workspace.loadIndexBase else { return }
            marksTask = Task { @MainActor [weak self] in
                guard let base = await load(path), !Task.isCancelled else {
                    self?.js("wb.marks([])"); return
                }
                let changes = await Task.detached(priority: .utility) { GutterDiff.changes(base: base.text, current: text) }.value
                guard let self, !Task.isCancelled, !self.dismantled, self.parent?.documentID == path else { return }
                let marks = changes.map { change -> [Any] in
                    let kind = change.old.isEmpty ? "add" : change.new.isEmpty ? "del" : "mod"
                    return [change.new.lowerBound, max(change.new.lowerBound, change.new.upperBound - 1), kind]
                }
                let data = (try? JSONSerialization.data(withJSONObject: marks)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                self.js("wb.marks(\(data))")
            }
        }

        private func scroll(toLine line: Int, smooth: Bool) {
            js("wb.scrollToLine(\(line), \(smooth))")
        }

        func dismantle() {
            dismantled = true
            renderTask?.cancel(); marksTask?.cancel()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "wb")
        }

        // MARK: Page events

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !loaded else { return }
            loaded = true
            PerfLog.interval("reader.templateLoad", since: createdAt)
            if let parent { update(parent) }
        }

        /// The page itself never navigates: links come through `wb` messages, anything else is opened outside.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if !loaded { decisionHandler(.allow); return }
            decisionHandler(.cancel)
            if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String,
                  let parent, !dismantled else { return }
            let workspace = parent.workspace, id = parent.documentID
            switch type {
            case "link":
                if let href = body["href"] as? String { workspace.followLink(href, from: id) }
            case "task":
                if let offset = body["offset"] as? Int {
                    do { try workspace.toggleTask(at: offset, in: id) } catch { workspace.errorMessage = error.localizedDescription }
                }
            case "top":
                if let line = body["line"] as? Int {
                    workspace.readerTopLine[id] = line
                    workspace.outline.updateCaret(offset(ofLine: line))
                }
            case "edit":
                guard let first = body["line"] as? Int else { workspace.editMarkdown(at: nil, in: id); return }
                let lines = range(lines: first, through: (body["end"] as? Int) ?? first)
                let exact = (body["text"] as? String).flatMap { Self.sourceRange(of: $0, in: parent.text, lines: lines) }
                workspace.editMarkdown(at: first, in: id, selecting: exact)
            case "send":
                guard let first = body["line"] as? Int, let last = body["end"] as? Int else { return }
                // What the page shows, not the Markdown under it: **粗体** goes as 粗体.
                if let text = body["text"] as? String, let send = workspace.sendTextToTerminal, TerminalSnippet.plain(text) != nil {
                    send(text, first == last ? "\(id):\(first + 1)" : "\(id):\(first + 1)-\(last + 1)")
                    return
                }
                let lines = range(lines: first, through: last)
                workspace.sendSelectionToTerminal?(lines)
            case "quote":
                guard let text = body["text"] as? String, let first = body["line"] as? Int, let last = body["end"] as? Int else { return }
                let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                let reference = first == last ? "\(id):\(first + 1)" : "\(id):\(first + 1)-\(last + 1)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(quoted + "\n\n— " + reference, forType: .string)
                workspace.showNotice("已复制为引用（\(reference)）")
            case "plain", "deai":
                guard let text = body["text"] as? String, let first = body["line"] as? Int, let last = body["end"] as? Int else { return }
                workspace.assistSelection?(type == "plain" ? .plain : .deAI, text, first == last ? "\(id):\(first + 1)" : "\(id):\(first + 1)-\(last + 1)")
            case "copy":
                if let text = body["text"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    workspace.showNotice("代码已复制")
                }
            default:
                break
            }
        }

        // MARK: Lines

        nonisolated static func lineStarts(_ text: String) -> [Int] {
            var starts = [0]
            var offset = 0
            for unit in text.utf16 {
                offset += 1
                if unit == 10 { starts.append(offset) }
            }
            return starts
        }
        private func offset(ofLine line: Int) -> Int { lineStarts[max(0, min(line, lineStarts.count - 1))] }
        private func line(at offset: Int) -> Int { max(0, (lineStarts.lastIndex { $0 <= offset } ?? 0)) }
        private func range(lines first: Int, through last: Int) -> NSRange {
            let start = offset(ofLine: first)
            let end = last + 1 < lineStarts.count ? lineStarts[last + 1] - 1 : (parent?.text.utf16.count ?? start)
            return NSRange(location: start, length: max(0, end - start))
        }

        /// Where text selected in the rendered page sits in the source. The rendered words have no `**`, backticks or
        /// link syntax, so the match is made on the selection's first and last few characters inside the block's lines,
        /// longest first. Nil when they cannot be found (the caller falls back to the whole lines).
        nonisolated static func sourceRange(of selected: String, in text: String, lines: NSRange) -> NSRange? {
            let source = text as NSString
            guard lines.location >= 0, NSMaxRange(lines) <= source.length else { return nil }
            let segment = source.substring(with: lines) as NSString
            let needle = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return nil }
            let whole = segment.range(of: needle)
            if whole.location != NSNotFound { return NSRange(location: lines.location + whole.location, length: whole.length) }
            let characters = Array(needle)
            var start: Int?
            for count in [12, 6, 3, 1] where count <= characters.count {
                let found = segment.range(of: String(characters.prefix(count)))
                if found.location != NSNotFound { start = found.location; break }
            }
            guard let start else { return nil }
            var end: Int?
            for count in [12, 6, 3, 1] where count <= characters.count {
                let found = segment.range(of: String(characters.suffix(count)), options: .backwards,
                                          range: NSRange(location: start, length: segment.length - start))
                if found.location != NSNotFound { end = NSMaxRange(found); break }
            }
            guard let end, end > start else { return nil }
            return NSRange(location: lines.location + start, length: end - start)
        }

        static func json(_ string: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
            let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
            return String(array.dropFirst().dropLast())
        }
    }
}

/// Keeps the user content controller from retaining the coordinator (it would otherwise never be released).
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: (any WKScriptMessageHandler)?) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A web view that lets the card's resize handles and the window keep their cursor and drag behaviour.
private final class ReaderWebView: WKWebView {
    override var mouseDownCanMoveWindow: Bool { false }
    /// ⌘F (and the Edit menu's Find) opens the page's own find bar; the editor's text finder does not reach a web view.
    override func performTextFinderAction(_ sender: Any?) { openFind() }
    @objc func performFindPanelAction(_ sender: Any?) { openFind() }
    func openFind() { evaluateJavaScript("wb.find()", completionHandler: nil) }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) || item.action == #selector(performFindPanelAction(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }
}

/// Serves images under the project root as `folmi-file://local/<path>`. Nothing outside the root, no dotfiles in
/// `.git`, and only image types, so a document cannot read arbitrary files into the page.
final class ProjectFileSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "folmi-file"
    /// Set when a prewarmed web view is handed to a project; nothing is served before that.
    var root: URL?
    init(root: URL?) { self.root = root }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let root, let data = Self.data(for: url, root: root) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    static func data(for url: URL, root: URL) -> Data? {
        let relative = url.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        guard !relative.isEmpty, relative.allSatisfy({ $0 != ".." && $0 != "." && $0.lowercased() != ".git" }),
              EditorWorkspace.imageExtensions.contains((relative.last! as NSString).pathExtension.lowercased()) else { return nil }
        let file = relative.reduce(root) { $0.appendingPathComponent($1) }.resolvingSymlinksInPath().standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.path.hasPrefix(base),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= MarkdownImageLimits.maximumBytes else { return nil }
        return try? Data(contentsOf: file)
    }
}

/// The reader page: one static template (styles keyed on CSS variables, the event script), filled by `wb.render`.
enum MarkdownReaderPage {
    /// An image target as a page URL: web images as they are, project images through the scheme handler.
    nonisolated static func imageSource(_ target: String, from documentPath: String) -> String? {
        if target.hasPrefix("https://") || target.hasPrefix("http://") || target.hasPrefix("data:image/") { return target }
        guard case let .file(path, _, _) = MarkdownLinks.resolve(target, from: documentPath) else { return nil }
        let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
        return "\(ProjectFileSchemeHandler.scheme)://local/" + encoded.joined(separator: "/")
    }

    /// CSS variables for the theme (both light and dark, the page follows the window) and the reading settings.
    @MainActor static func style(theme: FolmiTheme, presentation: EditorPresentation) -> String {
        let palette = theme.palette
        func vars(dark: Bool) -> String {
            func hex(_ color: NSColor, _ alpha: CGFloat? = nil) -> String {
                let c = ThemePalette.resolved(color, dark: dark)
                let a = alpha ?? c.alphaComponent
                return "rgba(\(Int(c.redComponent * 255)),\(Int(c.greenComponent * 255)),\(Int(c.blueComponent * 255)),\(String(format: "%.3f", a)))"
            }
            return """
            --bg:\(hex(palette.card));--fg:\(hex(palette.foreground));--muted:\(hex(palette.comment));--border:\(hex(palette.border));
            --accent:\(hex(palette.accent));--on-accent:\(hex(palette.onAccent));--link:\(hex(palette.link));--accent-bg:\(hex(palette.accent, 0.14));--code-bg:\(hex(palette.foreground, dark ? 0.06 : 0.045));
            --sel:\(hex(palette.selection));--add-bg:\(hex(palette.added, dark ? 0.14 : 0.10));--del-bg:\(hex(palette.removed, dark ? 0.12 : 0.08));--add:\(hex(palette.added));--mod:\(hex(palette.modified));--del:\(hex(palette.removed));
            --pop:\(dark ? "rgba(48,51,62,.78)" : "rgba(255,255,255,.82)");--edge:\(dark ? "rgba(255,255,255,.10)" : "rgba(255,255,255,.8)");
            --t-keyword:\(hex(palette.keyword));--t-string:\(hex(palette.string));--t-number:\(hex(palette.number));--t-comment:\(hex(palette.comment));
            --t-type:\(hex(palette.type));--t-variable:\(hex(palette.variable));--t-literal:\(hex(palette.number));
            """
        }
        let family: String
        switch presentation.proseFontFamily {
        case "": family = "-apple-system, \"PingFang SC\", \"Helvetica Neue\", sans-serif"
        case "serif": family = "\"New York\", ui-serif, \"Songti SC\", serif"
        default: family = "\"\(presentation.proseFontFamily)\", -apple-system, sans-serif"
        }
        let size = presentation.proseFontSize.isFinite ? min(32, max(10, presentation.proseFontSize)) : 16
        let width = presentation.readingWidth > 0 ? "\(Int(presentation.readingWidth))px" : "none"
        return """
        :root{\(vars(dark: false))--font:\(family);--code-font:"\(presentation.fontFamily)", "SF Mono", Menlo, monospace;--size:\(Int(size))px;--width:\(width);}
        @media (prefers-color-scheme: dark){:root{\(vars(dark: true))}}
        """
    }

    static let template = """
    <!doctype html><html><head><meta charset="utf-8">
    <style id="vars"></style>
    <style>
    *{box-sizing:border-box}
    html,body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--font);font-size:var(--size);line-height:1.75;
      -webkit-font-smoothing:antialiased;-webkit-text-size-adjust:none}
    ::selection{background:var(--sel)}
    #doc{max-width:var(--width);margin:0 auto;padding:28px 44px 120px;overflow-wrap:break-word}
    #doc>:first-child{margin-top:0}
    h1,h2,h3,h4,h5,h6{line-height:1.3;margin:1.6em 0 .55em;font-weight:650;scroll-margin-top:16px}
    h1{font-size:1.9em;letter-spacing:-.01em;margin-top:.4em}
    h2{font-size:1.4em;padding-bottom:.25em;border-bottom:1px solid var(--border)}
    h3{font-size:1.18em}h4{font-size:1.02em}h5,h6{font-size:.92em;color:var(--muted)}
    p{margin:0 0 .85em}
    a{color:var(--link);text-decoration:none;cursor:pointer}a:hover{text-decoration:underline}
    a.wiki{border-bottom:1px dashed currentColor}a.wiki:hover{text-decoration:none}
    strong{font-weight:650}mark{background:rgba(250,199,117,.45);color:inherit;border-radius:3px;padding:0 2px}
    code{font-family:var(--code-font);font-size:.86em;background:var(--code-bg);padding:.12em .38em;border-radius:5px}
    kbd{font-family:var(--code-font);font-size:.8em;border:1px solid var(--border);border-bottom-width:2px;border-radius:5px;padding:.05em .4em}
    .code{position:relative;margin:.4em 0 1.1em;background:var(--code-bg);border:1px solid var(--border);border-radius:10px}
    .code pre{margin:0;padding:14px 16px;overflow:auto;font-family:var(--code-font);font-size:.82em;line-height:1.6}
    .code pre code{background:none;padding:0;font-size:1em}
    .math.display{display:block;margin:.6em 0 1em;overflow-x:auto;overflow-y:hidden;text-align:center}
    .math>code{white-space:pre-wrap}.math.display>code{display:inline-block;text-align:left}
    .math[data-error]>code{color:var(--del)}.math .katex{font-size:1.08em}.math.display .katex-display{margin:0}
    .mermaid{margin:.6em 0 1.1em;text-align:center;overflow-x:auto}
    .mermaid .src{text-align:left;margin:0;padding:14px 16px;background:var(--code-bg);border:1px solid var(--border);border-radius:10px;font-family:var(--code-font);font-size:.82em;line-height:1.6;white-space:pre-wrap}
    .mermaid[data-done] .src{display:none}.mermaid .chart svg{max-width:100%;height:auto}
    .mermaid[data-error]::after{content:attr(data-error);display:block;margin-top:6px;text-align:left;font:12px -apple-system,sans-serif;color:var(--del)}
    .code .tools{position:absolute;top:6px;right:8px;display:flex;gap:4px;align-items:center;font-family:-apple-system,sans-serif;font-size:11px;color:var(--muted);opacity:.0;transition:opacity .15s}
    .code:hover .tools{opacity:1}.code .tools button{font:inherit;color:inherit;background:var(--pop);border:1px solid var(--border);border-radius:6px;padding:2px 8px;cursor:pointer}
    .tok-keyword{color:var(--t-keyword)}.tok-string{color:var(--t-string)}.tok-number{color:var(--t-number)}.tok-comment{color:var(--t-comment);font-style:italic}
    .tok-type{color:var(--t-type)}.tok-variable{color:var(--t-variable)}.tok-literal{color:var(--t-literal)}
    blockquote{margin:0 0 1em;padding:.1em 1em;border-left:3px solid var(--border);color:var(--muted)}
    .alert{margin:0 0 1em;padding:.5em 1em;border-left:3px solid var(--accent);background:var(--accent-bg);border-radius:0 8px 8px 0}
    .alert-title{font-weight:650;margin:0 0 .2em}.alert.warning,.alert.caution{border-color:var(--mod)}.alert.caution{border-color:var(--del)}
    .alert>:last-child,blockquote>:last-child,li>:last-child{margin-bottom:0}
    ul,ol{margin:0 0 .9em;padding-left:1.6em}li{margin:.15em 0}ul.tight>li>p,ol.tight>li>p{margin:0}
    ul.tasks{list-style:none;padding-left:.2em}ul.tasks ul.tasks{padding-left:1.4em}
    li.task-item{display:grid;grid-template-columns:auto minmax(0,1fr);column-gap:.55em;align-items:start}li.task-item>:not(input){grid-column:2}
    input.task{appearance:none;-webkit-appearance:none;flex:none;width:1.05em;height:1.05em;margin:.38em 0 0;border:1.5px solid var(--muted);border-radius:5px;cursor:pointer;display:grid;place-items:center;transition:background .12s,border-color .12s}
    input.task:checked{background:var(--accent);border-color:var(--accent)}
    input.task:checked::after{content:"";width:.28em;height:.55em;border:solid var(--on-accent);border-width:0 2px 2px 0;transform:translateY(-.06em) rotate(45deg)}
    li.task-item:has(>input:checked)>p,li.task-item:has(>input:checked)>p *{color:var(--muted);text-decoration:line-through}
    hr{border:0;border-top:1px solid var(--border);margin:1.8em 0}
    .table{overflow-x:auto;margin:.4em 0 1.2em;border:1px solid var(--border);border-radius:10px}
    table{border-collapse:collapse;font-size:.9em;line-height:1.6;min-width:100%;font-variant-numeric:tabular-nums}
    th,td{padding:.6em .95em;border-bottom:1px solid var(--border);text-align:left;vertical-align:top}
    tbody tr:last-child>td{border-bottom:0}
    th{font-weight:650;color:var(--muted);background:var(--code-bg);word-break:keep-all;vertical-align:bottom}
    td{word-break:normal;line-break:strict}
    img{max-width:100%;border-radius:8px}
    .missing-image{display:inline-block;padding:.2em .6em;border:1px dashed var(--border);border-radius:6px;color:var(--muted);font-size:.85em}
    .missing-image::before{content:"图片不可用 · "}
    .frontmatter{font-family:var(--code-font);font-size:.78em;color:var(--muted);background:var(--code-bg);border-radius:8px;padding:10px 14px;margin:0 0 1.4em;white-space:pre-wrap}
    [data-mark]{position:relative}
    [data-mark]::before{content:"";position:absolute;left:-18px;top:.25em;bottom:.25em;width:3px;border-radius:2px;background:var(--mod)}
    [data-mark="add"]::before{background:var(--add)}
    body.diff [data-mark="add"],body.diff [data-mark="mod"]{background:var(--add-bg);border-radius:6px;box-shadow:0 0 0 5px var(--add-bg)}
    .diff-old{margin:0 0 .9em;padding:.35em .9em;border-left:3px solid var(--del);border-radius:0 8px 8px 0;background:var(--del-bg);
      color:var(--muted);text-decoration:line-through;text-decoration-color:var(--del)}
    .diff-old>:last-child{margin-bottom:0}.diff-old .code{opacity:.8}
    [data-mark="del"]::before{top:auto;bottom:-.45em;height:0;width:8px;border:5px solid transparent;border-left-color:var(--del);background:none;left:-20px}
    li[data-mark]::before{left:-38px}ul.tasks>li[data-mark]::before{left:-22px}
    mark.find{background:rgba(250,199,117,.45);color:inherit;border-radius:2px;padding:0}
    mark.find.current{background:rgba(239,159,39,.9);color:#1d1e22}
    #find{position:fixed;top:10px;right:14px;z-index:20;display:none;align-items:center;gap:4px;padding:5px 6px 5px 10px;border-radius:10px;background:var(--pop);
      -webkit-backdrop-filter:blur(20px) saturate(1.6);backdrop-filter:blur(20px) saturate(1.6);
      box-shadow:inset 0 1px 0 var(--edge),0 0 0 1px var(--border),0 8px 24px rgba(0,0,0,.22);font:12.5px -apple-system,"PingFang SC",sans-serif}
    #find.on{display:flex}
    #find input{width:190px;font:inherit;color:var(--fg);background:var(--code-bg);border:1px solid var(--border);border-radius:6px;padding:4px 8px;outline:none}
    #find input:focus{border-color:var(--accent)}
    #find .n{min-width:44px;text-align:right;color:var(--muted);font-variant-numeric:tabular-nums}
    #find button{font:inherit;color:var(--fg);background:none;border:0;width:24px;height:24px;border-radius:6px;cursor:pointer}
    #find button:hover{background:var(--code-bg)}
    #pop{position:absolute;z-index:10;display:none;gap:2px;padding:4px;border-radius:10px;background:var(--pop);
      -webkit-backdrop-filter:blur(20px) saturate(1.6);backdrop-filter:blur(20px) saturate(1.6);
      box-shadow:inset 0 1px 0 var(--edge),0 0 0 1px var(--border),0 8px 24px rgba(0,0,0,.22);font:12.5px -apple-system,"PingFang SC",sans-serif;white-space:nowrap}
    .flash{animation:wbflash 3s ease-out}@keyframes wbflash{0%,25%{background:var(--accent-bg);box-shadow:0 0 0 6px var(--accent-bg)}100%{background:transparent;box-shadow:0 0 0 6px transparent}}
    @media (prefers-reduced-motion:reduce){.flash{animation:none;background:var(--accent-bg)}*{transition:none!important}}
    #pop.on{display:flex}#pop button{font:inherit;color:var(--fg);background:none;border:0;padding:5px 10px;border-radius:7px;cursor:pointer}
    #pop button:hover{background:var(--code-bg)}#pop button.primary{color:var(--accent);background:var(--accent-bg)}
    </style></head><body><main id="doc"></main>
    <div id="find"><input id="find-q" placeholder="在文档中查找" spellcheck="false"><span class="n" id="find-n"></span>
    <button data-dir="-1" title="上一个（⇧↩）">↑</button><button data-dir="1" title="下一个（↩）">↓</button><button data-dir="0" title="关闭（Esc）">✕</button></div>
    <div id="pop"><button class="primary" data-act="send">发到终端</button><button data-act="quote">复制为引用</button><button data-act="plain">说人话</button><button data-act="deai">去 AI 腔</button><button data-act="edit">编辑这里</button></div>
    <script>
    (function(){
    const post=(m)=>window.webkit.messageHandlers.wb.postMessage(m);
    const doc=document.getElementById('doc'),pop=document.getElementById('pop');
    let marks=[];
    function blocks(){return doc.querySelectorAll('[data-line]')}
    function topBlock(){
      let best=null;for(const el of blocks()){if(el.closest('#pop'))continue;const r=el.getBoundingClientRect();
        if(r.bottom>8){if(!best||r.top<=8)best=el;if(r.top>8)break}}return best}
    function decorate(){
      doc.querySelectorAll('.code').forEach(c=>{const t=document.createElement('div');t.className='tools';
        if(c.dataset.lang){const s=document.createElement('span');s.textContent=c.dataset.lang;t.appendChild(s)}
        const b=document.createElement('button');b.textContent='复制';b.onclick=(e)=>{e.stopPropagation();post({type:'copy',text:c.querySelector('code').innerText})};
        t.appendChild(b);c.appendChild(t)});
      typeset();applyMarks()}
    // Formulas and diagrams: KaTeX / Mermaid are bundled and loaded only once a document has one, so other documents
    // pay nothing. Ready libraries typeset synchronously (no jump on every keystroke); diagrams are cached by source.
    const ASSET='folmi-asset://local/';let katexReady=null,mermaidReady=null,chartSeq=0;const charts=new Map();
    function load(src){return new Promise((ok,no)=>{const e=document.createElement('script');e.src=ASSET+src;e.onload=ok;e.onerror=no;document.head.appendChild(e)})}
    function typeset(){
      const math=doc.querySelectorAll('.math:not([data-done])');
      if(math.length){if(window.katex)typesetMath(math);
        else{if(!katexReady){const l=document.createElement('link');l.rel='stylesheet';l.href=ASSET+'katex/katex.min.css';document.head.appendChild(l);
          katexReady=load('katex/katex.min.js')}katexReady.then(()=>typesetMath(doc.querySelectorAll('.math:not([data-done])')),()=>{})}}
      const boxes=doc.querySelectorAll('.mermaid:not([data-done])');
      if(boxes.length){if(!mermaidReady)mermaidReady=load('mermaid/mermaid.min.js');
        boxes.forEach(placeCached);mermaidReady.then(()=>drawCharts(),()=>{})}}
    function typesetMath(list){for(const el of list){try{katex.render(el.dataset.tex,el,{displayMode:el.classList.contains('display'),throwOnError:true,output:'htmlAndMathml'});el.removeAttribute('data-error')}
      catch(e){el.dataset.error=String(e.message||e);el.title=el.dataset.error}el.dataset.done='1'}}
    function chartTheme(){const v=getComputedStyle(document.documentElement),g=(n)=>v.getPropertyValue(n).trim();
      return {dark:matchMedia('(prefers-color-scheme: dark)').matches,page:g('--bg'),bg:g('--code-bg'),fg:g('--fg'),line:g('--muted'),accent:g('--accent'),border:g('--border'),font:getComputedStyle(doc).fontFamily}}
    function chartKey(el,t){return JSON.stringify(t)+'\\u0000'+el.querySelector('.src').textContent}
    function placeCached(el){const svg=charts.get(chartKey(el,chartTheme()));if(svg===undefined)return false;
      const box=document.createElement('div');box.className='chart';box.innerHTML=svg;el.appendChild(box);el.dataset.done='1';return true}
    let drawing=false;
    async function drawCharts(){if(drawing)return;drawing=true;
      try{const t=chartTheme();
        mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'base',darkMode:t.dark,fontFamily:t.font,
          themeVariables:{darkMode:t.dark,background:'transparent',primaryColor:t.bg,secondaryColor:t.bg,tertiaryColor:t.bg,primaryTextColor:t.fg,
            textColor:t.fg,primaryBorderColor:t.accent,lineColor:t.line,clusterBkg:t.bg,clusterBorder:t.border,noteBkgColor:t.bg,noteTextColor:t.fg,edgeLabelBackground:t.page,labelBackground:t.page,fontFamily:t.font}});
        for(const el of doc.querySelectorAll('.mermaid:not([data-done])')){if(placeCached(el))continue;
          const key=chartKey(el,t);let svg;
          try{svg=(await mermaid.render('wbchart'+(++chartSeq),el.querySelector('.src').textContent)).svg;el.removeAttribute('data-error')}
          catch(e){svg='';el.dataset.error='图表有误：'+String(e.message||e).split('\\n')[0];document.querySelectorAll('[id^="dwbchart"]').forEach(n=>n.remove())}
          charts.set(key,svg);if(charts.size>60)charts.delete(charts.keys().next().value);
          if(el.isConnected&&svg){const box=document.createElement('div');box.className='chart';box.innerHTML=svg;el.appendChild(box);el.dataset.done='1'}}}
      finally{drawing=false}
      if(doc.querySelector('.mermaid:not([data-done]):not([data-error])'))drawCharts()}
    // Light / dark switch: diagrams are drawn again in the other colors.
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change',()=>{doc.querySelectorAll('.mermaid[data-done]').forEach(el=>{el.removeAttribute('data-done');el.querySelector('.chart')?.remove()});typeset()});
    function applyMarks(){
      doc.querySelectorAll('[data-mark]').forEach(e=>e.removeAttribute('data-mark'));
      if(!marks.length)return;
      // Innermost blocks only; a table is marked whole, and a list item's first paragraph marks the item (by its bullet).
      const leaves=[...blocks()].filter(e=>e.matches('.table')||(!e.matches('tr')&&!e.querySelector('[data-line]')));
      for(const [s,e,k] of marks){for(const el of leaves){const a=+el.dataset.line,b=+el.dataset.end;
        if(k==='del'?(a<=s-1&&s-1<=b):(a<=e&&s<=b)){
          const li=el.parentElement&&el.parentElement.matches('li')&&el.parentElement.firstElementChild===el?el.parentElement
            :(el.parentElement&&el.parentElement.matches('li.task-item')&&el===el.parentElement.querySelector(':scope>[data-line]')?el.parentElement:null);
          (li||el).setAttribute('data-mark',k)}}}}
    const bar=document.getElementById('find'),fq=document.getElementById('find-q'),fn=document.getElementById('find-n');
    let hits=[],cur=-1;
    function clearFind(){const parents=new Set();doc.querySelectorAll('mark.find').forEach(m=>{const p=m.parentNode;p.replaceChild(document.createTextNode(m.textContent),m);parents.add(p)});
      parents.forEach(p=>p.normalize());hits=[];cur=-1}
    function runFind(keepIndex){const q=fq.value,old=cur;clearFind();if(!q){fn.textContent='';return}
      const ql=q.toLowerCase(),nodes=[],w=document.createTreeWalker(doc,NodeFilter.SHOW_TEXT,{acceptNode:n=>n.parentElement.closest('.tools,.katex-mathml,.mermaid .src')?2:1});
      while(w.nextNode())nodes.push(w.currentNode);
      for(const n of nodes){const lower=n.nodeValue.toLowerCase(),found=[];let i=lower.indexOf(ql);
        while(i>=0&&hits.length+found.length<2000){found.push(i);i=lower.indexOf(ql,i+ql.length)}
        const marks=[];for(let k=found.length-1;k>=0;k--){const m=n.splitText(found[k]);m.splitText(q.length);
          const mk=document.createElement('mark');mk.className='find';m.parentNode.replaceChild(mk,m);mk.appendChild(m);marks.unshift(mk)}
        hits.push(...marks)}
      if(!hits.length){fn.textContent='无结果';return}
      go(keepIndex&&old>=0?Math.min(old,hits.length-1):firstVisible(),!keepIndex)}
    function firstVisible(){const i=hits.findIndex(h=>h.getBoundingClientRect().top>=0);return i<0?0:i}
    function go(i,scroll){if(!hits.length)return;if(cur>=0&&hits[cur])hits[cur].classList.remove('current');
      cur=(i+hits.length)%hits.length;hits[cur].classList.add('current');fn.textContent=(cur+1)+'/'+hits.length;
      if(scroll!==false)hits[cur].scrollIntoView({block:'center'})}
    function closeFind(){clearFind();bar.classList.remove('on');fn.textContent=''}
    fq.addEventListener('input',()=>runFind(false));
    fq.addEventListener('keydown',(e)=>{if(e.key==='Enter'){e.preventDefault();go(cur+(e.shiftKey?-1:1))}
      else if(e.key==='Escape'){e.preventDefault();closeFind()}});
    bar.addEventListener('click',(e)=>{const b=e.target.closest('button');if(!b)return;const d=+b.dataset.dir;if(d===0)closeFind();else go(cur+d);fq.focus()});
    window.wb={
      find(){const sel=window.getSelection().toString().trim();if(sel&&!sel.includes('\\n'))fq.value=sel;
        bar.classList.add('on');hide();fq.focus();fq.select();runFind(false)},
      style(css){document.getElementById('vars').textContent=css},
      render(html,line,fresh){
        const anchor=fresh?null:topBlock(),key=anchor?anchor.dataset.line:null,delta=anchor?anchor.getBoundingClientRect().top:0;
        doc.innerHTML=html;decorate();hide();if(bar.classList.contains('on')&&fq.value)runFind(true);
        if(line!==null&&line!==undefined){wb.scrollToLine(line,false)}
        else if(key!==null){const el=doc.querySelector('[data-line="'+key+'"]');if(el)window.scrollBy(0,el.getBoundingClientRect().top-delta)}
        else if(fresh){window.scrollTo(0,0)}},
      marks(list){marks=list||[];applyMarks()},
      olds(list){doc.querySelectorAll('.diff-old').forEach(e=>e.remove());document.body.classList.toggle('diff',!!list);if(!list)return;
        const leaves=[...blocks()].filter(e=>e.matches('.table')||(!e.matches('tr')&&!e.querySelector('[data-line]')));
        for(const [line,html] of list){const box=document.createElement('div');box.className='diff-old';box.innerHTML=html;
          box.querySelectorAll('[data-line]').forEach(e=>{e.removeAttribute('data-line');e.removeAttribute('data-end')});
          let at=leaves.find(e=>+e.dataset.line>=line);
          if(at){const li=at.parentElement&&at.parentElement.matches('li')?at.parentElement:null;if(li)at=li;at.parentNode.insertBefore(box,at)}
          else doc.appendChild(box)}},
      flash(ranges){const hit=[];const leaves=[...blocks()].filter(e=>e.matches('.table')||(!e.matches('tr')&&!e.querySelector('[data-line]')));
        for(const el of leaves){const a=+el.dataset.line,b=+(el.dataset.end||el.dataset.line);
        if(ranges.some(r=>r[0]<=b&&r[1]>=a))hit.push(el)}
        for(const el of hit){el.classList.remove('flash');void el.offsetWidth;el.classList.add('flash');setTimeout(()=>el.classList.remove('flash'),3200)}},
      scrollToLine(line,smooth){let target=null;for(const el of blocks()){if(+el.dataset.line<=line)target=el;else break}
        if(!target){window.scrollTo(0,0);return}
        if(line===0&&+target.dataset.line===0){window.scrollTo(0,0);return}
        target.scrollIntoView({block:'start',behavior:smooth?'smooth':'auto'})}
    };
    let scrollTimer=null;
    window.addEventListener('scroll',()=>{hide();clearTimeout(scrollTimer);scrollTimer=setTimeout(()=>{const t=topBlock();if(t)post({type:'top',line:+t.dataset.line})},120)},{passive:true});
    document.addEventListener('click',(e)=>{
      const box=e.target.closest('input.task');if(box){e.preventDefault();post({type:'task',offset:+box.dataset.offset});return}
      const a=e.target.closest('a[data-href]');if(a){e.preventDefault();const h=a.dataset.href;
        if(h.startsWith('#')&&!h.startsWith('#L')){const el=document.getElementById(decodeURIComponent(h.slice(1)).toLowerCase().replace(/ /g,'-'));if(el){el.scrollIntoView({behavior:'smooth'});return}}
        post({type:'link',href:h})}});
    function lineOf(node,attr){let el=node&&(node.nodeType===1?node:node.parentElement);el=el&&el.closest('[data-line]');return el?+el.dataset[attr]:null}
    function selectionInfo(){const s=window.getSelection();if(!s||s.isCollapsed||!s.rangeCount)return null;
      const r=s.getRangeAt(0);if(!doc.contains(r.commonAncestorContainer))return null;
      let a=lineOf(r.startContainer,'line'),b=lineOf(r.endContainer,'end');if(a===null||b===null)return null;if(b<a)b=a;
      return {text:s.toString(),line:a,end:b,rect:r.getBoundingClientRect()}}
    function hide(){pop.classList.remove('on')}
    document.addEventListener('mouseup',()=>setTimeout(()=>{const info=selectionInfo();if(!info||!info.text.trim()){hide();return}
      pop.classList.add('on');const w=pop.offsetWidth,x=Math.max(8,Math.min(window.innerWidth-w-8,info.rect.left+info.rect.width/2-w/2+window.scrollX));
      const y=info.rect.top+window.scrollY-pop.offsetHeight-8;pop.style.left=x+'px';pop.style.top=(y<window.scrollY+4?info.rect.bottom+window.scrollY+8:y)+'px'},0));
    document.addEventListener('mousedown',(e)=>{if(!e.target.closest('#pop'))hide()});
    pop.addEventListener('mousedown',(e)=>e.preventDefault());
    pop.addEventListener('click',(e)=>{const b=e.target.closest('button');const info=selectionInfo();if(!b||!info)return;
      const act=b.dataset.act;if(act==='send')post({type:'send',line:info.line,end:info.end,text:info.text});
      else if(act==='quote')post({type:'quote',text:info.text.trim(),line:info.line,end:info.end});
      else if(act==='plain'||act==='deai')post({type:act,text:info.text.trim(),line:info.line,end:info.end});
      else if(act==='edit')post({type:'edit',line:info.line,end:info.end,text:info.text});hide();window.getSelection().removeAllRanges()});
    document.addEventListener('keydown',(e)=>{if(e.key==='Escape')hide()});
    })();
    </script></body></html>
    """
}

/// One reader web view built and loaded ahead of time, so the first Markdown file opens without the ~0.5 s it takes
/// WebKit to start a page. The view is not tied to a project until `MarkdownReaderView` takes it.
@MainActor
enum ReaderWebViewPool {
    @MainActor struct Prepared {
        let webView: WKWebView
        let files: ProjectFileSchemeHandler
        let messages: WeakMessageHandler
        var loaded: Bool { tracker.loaded }
        fileprivate let tracker: LoadTracker
    }
    private static var spare: Prepared?
    private static var refillScheduled = false

    static func warm() { if spare == nil { spare = make() } }
    static func take() -> Prepared? { defer { spare = nil }; return spare }
    /// Builds the next spare once the app is idle, for the next project's editor.
    static func refillLater() {
        guard !refillScheduled else { return }
        refillScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refillScheduled = false; warm() }
    }
    static func make() -> Prepared {
        let configuration = WKWebViewConfiguration()
        let files = ProjectFileSchemeHandler(root: nil)
        configuration.setURLSchemeHandler(files, forURLScheme: ProjectFileSchemeHandler.scheme)
        configuration.setURLSchemeHandler(ReaderAssetSchemeHandler(), forURLScheme: ReaderAssetSchemeHandler.scheme)
        let messages = WeakMessageHandler(nil)
        configuration.userContentController.add(messages, name: "wb")
        configuration.preferences.isTextInteractionEnabled = true
        let webView = ReaderWebView(frame: .zero, configuration: configuration)
        let tracker = LoadTracker()
        webView.navigationDelegate = tracker
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.loadHTMLString(MarkdownReaderPage.template, baseURL: URL(string: "\(ProjectFileSchemeHandler.scheme)://local/"))
        return Prepared(webView: webView, files: files, messages: messages, tracker: tracker)
    }

    /// Remembers that the template finished loading before a reader took the view over.
    fileprivate final class LoadTracker: NSObject, WKNavigationDelegate {
        var loaded = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    }
}

/// Rendered HTML of recently shown documents, so switching back to one skips the Markdown → HTML pass.
@MainActor
enum ReaderRenderCache {
    struct Entry: Sendable {
        let path: String
        let text: String
        let html: String
        let layout: MarkdownSections
        let starts: [Int]
    }
    private static var entries: [Entry] = []
    static func find(path: String, text: String) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.path == path && $0.text == text }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry
    }
    /// Renders off the main thread and keeps the result. A prefetch of the same text already under way is reused.
    static func render(path: String, text: String, priority: TaskPriority) async -> Entry {
        if let cached = find(path: path, text: text) { return cached }
        let key = path + "\0" + String(text.hashValue)
        if let running = inFlight[key] { return await running.value }
        let task = Task.detached(priority: priority) { () -> Entry in
            var options = MarkdownHTML.Options()
            options.documentPath = path
            options.imageSource = { MarkdownReaderPage.imageSource($0, from: path) }
            return Entry(path: path, text: text, html: MarkdownHTML.render(text, options: options),
                         layout: MarkdownOutline.layout(text), starts: MarkdownReaderView.Coordinator.lineStarts(text))
        }
        inFlight[key] = task
        let entry = await task.value
        inFlight[key] = nil
        store(entry)
        return entry
    }
    private static var inFlight: [String: Task<Entry, Never>] = [:]

    /// Renders documents the reader is likely to open next (changed or open Markdown files), quietly, so the first
    /// open is as fast as a return visit. Only the newest few are kept so prefetching never evicts what is on screen.
    static func prefetch(_ documents: [(path: String, text: String)]) {
        for document in documents.prefix(maximumPrefetch) where find(path: document.path, text: document.text) == nil {
            Task { @MainActor in _ = await render(path: document.path, text: document.text, priority: .utility) }
        }
    }
    static let maximumPrefetch = 8

    static func store(_ entry: Entry) {
        entries.removeAll { $0.path == entry.path }
        entries.append(entry)
        // Bounded by size, not count: a few long documents must not pin many megabytes.
        while entries.count > 1, entries.reduce(0, { $0 + $1.html.utf8.count + $1.text.utf8.count }) > 12 * 1024 * 1024 || entries.count > 16 {
            entries.removeFirst()
        }
    }
}
