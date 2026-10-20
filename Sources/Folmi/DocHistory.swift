import FolmiCore
import SwiftUI
import WebKit

/// A Markdown file through its commits: each version rendered, with what that commit changed marked beside it.
struct DocHistorySheet: View {
    let model: FolmiModel
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [GitRepository.FileRevision] = []
    @State private var selected: String?
    @State private var page: (html: String, marks: [[Any]])?
    @State private var loading = true
    @State private var note: String?

    private var path: String? { model.editorWorkspace?.selectedDocument?.path }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("演变史").themedFont(.headline, points: 13)
                Text(path ?? "").themedFont(.caption.monospaced(), points: 10).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            HStack(spacing: 0) {
                List(revisions, selection: $selected) { revision in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(revision.subject).themedFont(.callout, points: 12).lineLimit(2)
                        Text("\(revision.shortID) · \(revision.author) · \(revision.date.formatted(date: .abbreviated, time: .shortened))")
                            .themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                    }.tag(revision.id)
                }
                .frame(width: 270)
                Divider()
                ZStack {
                    if let page {
                        StaticReaderView(html: page.html, marks: page.marks, theme: model.theme, presentation: model.editorPresentation,
                                         root: model.repositoryURL)
                    }
                    if loading { ProgressView() }
                    if let note, !loading { Text(note).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 1040, height: 700)
        .task { await loadRevisions() }
        .onChange(of: selected) { _, id in Task { await show(id) } }
    }

    private func loadRevisions() async {
        guard let repository = model.repository, let path else { loading = false; note = "先打开一份 Markdown"; return }
        revisions = (try? await repository.fileHistory(path: path)) ?? []
        loading = false
        if revisions.isEmpty { note = "这份文档还没有提交记录" }
        selected = revisions.first?.id
    }

    private func show(_ id: String?) async {
        guard let id, let repository = model.repository, let revision = revisions.first(where: { $0.id == id }) else { return }
        loading = true
        defer { loading = false }
        let text = (try? await repository.fileText(commit: id, path: revision.path)) ?? ""
        var previous = ""
        if let parent = try? await repository.parent(of: id) {
            // Same path in the parent, else the path of the next older revision (the file was renamed in this commit).
            if let text = try? await repository.fileText(commit: parent, path: revision.path) { previous = text }
            else if let index = revisions.firstIndex(where: { $0.id == id }), revisions.indices.contains(index + 1),
                    let text = try? await repository.fileText(commit: parent, path: revisions[index + 1].path) { previous = text }
        }
        guard selected == id else { return }
        let rendered = await Task.detached(priority: .userInitiated) { () -> RenderedRevision in
            var options = MarkdownHTML.Options()
            options.documentPath = revision.path
            let html = MarkdownHTML.render(text, options: options)
            let marks: [[Any]] = GutterDiff.changes(base: previous, current: text).map { change in
                let kind = change.old.isEmpty ? "add" : change.new.isEmpty ? "del" : "mod"
                return [change.new.lowerBound, max(change.new.lowerBound, change.new.upperBound - 1), kind]
            }
            return RenderedRevision(html: html, marks: marks)
        }.value
        page = (rendered.html, rendered.marks)
        note = text.isEmpty ? "这个提交里没有这份文件" : nil
    }
}

/// The reader page showing fixed HTML (no editing, no links out of the sheet).
struct StaticReaderView: NSViewRepresentable {
    let html: String
    let marks: [[Any]]
    /// Removed text to show struck through (rendered diffs); nil for a plain page.
    var olds: [[Any]]? = nil
    let theme: FolmiTheme
    let presentation: EditorPresentation
    let root: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let prepared = ReaderWebViewPool.make()
        prepared.files.root = root
        prepared.webView.navigationDelegate = context.coordinator
        context.coordinator.webView = prepared.webView
        return prepared.webView
    }
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pending = self
        context.coordinator.apply()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var pending: StaticReaderView?
        private var loaded = false
        func apply() {
            guard loaded, let view = pending, let webView else { return }
            let style = MarkdownReaderPage.style(theme: view.theme, presentation: view.presentation)
            let marks = (try? JSONSerialization.data(withJSONObject: view.marks)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let olds = view.olds.flatMap { (try? JSONSerialization.data(withJSONObject: $0)).flatMap { String(data: $0, encoding: .utf8) } } ?? "null"
            webView.evaluateJavaScript("wb.style(\(MarkdownReaderView.Coordinator.json(style)));wb.render(\(MarkdownReaderView.Coordinator.json(view.html)),null,true);wb.marks(\(marks));wb.olds(\(olds))")
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; apply() }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(loaded ? .cancel : .allow)
        }
    }
}

/// One revision rendered off the main thread: its HTML and the changed-line marks for the reader (strings and numbers).
private struct RenderedRevision: @unchecked Sendable {
    let html: String
    let marks: [[Any]]
}
