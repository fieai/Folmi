import FolmiCore
import SwiftUI

/// A Markdown change shown the way it reads: the new version rendered, added and changed blocks tinted, and the text
/// they replaced (or that was removed) rendered just above them, struck through.
enum MarkdownDiffPage {
    /// Built off the main thread and handed back; immutable, and its `Any` values are only strings and numbers.
    struct Page: @unchecked Sendable {
        let html: String
        /// `[firstLine, lastLine, "add" | "mod"]` in the new text.
        let marks: [[Any]]
        /// `[newLine, html]`: removed or replaced text, shown before the block at `newLine`.
        let olds: [[Any]]
    }

    static func build(path: String, base: String, current: String) -> Page {
        var options = MarkdownHTML.Options()
        options.documentPath = path
        options.imageSource = { MarkdownReaderPage.imageSource($0, from: path) }
        let html = MarkdownHTML.render(current, options: options)
        let changes = GutterDiff.changes(base: base, current: current)
        let oldLines = GutterDiff.lines(base)
        let marks: [[Any]] = changes.filter { !$0.new.isEmpty }.map {
            [$0.new.lowerBound, max($0.new.lowerBound, $0.new.upperBound - 1), $0.old.isEmpty ? "add" : "mod"]
        }
        let olds: [[Any]] = changes.compactMap { change in
            guard !change.old.isEmpty, change.old.upperBound <= oldLines.count else { return nil }
            var snippet = oldLines[change.old].joined()
            guard !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            // Lines from inside a fenced block would otherwise render as prose.
            if insideFence(oldLines[..<change.old.lowerBound]) {
                snippet = "```\n" + snippet + (snippet.hasSuffix("\n") ? "" : "\n") + "```\n"
            }
            return [change.new.lowerBound, MarkdownHTML.render(snippet, options: options)]
        }
        return Page(html: html, marks: marks, olds: olds)
    }

    private static func insideFence(_ lines: ArraySlice<String>) -> Bool {
        var open = false
        for line in lines {
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { open.toggle() }
        }
        return open
    }

    /// The editor's form of text (no BOM, "\n" line ends), so both sides compare by content only.
    static func normalized(_ text: String) -> String {
        var text = text
        while text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

extension FolmiModel {
    /// Both sides of a file change as text: index → work tree for unstaged changes, HEAD → index for staged ones.
    func markdownDiffTexts(_ diff: FileDiff) async -> (base: String, current: String)? {
        guard let repository, let root = repositoryURL else { return nil }
        let path = diff.file.path
        func indexText() async -> String {
            guard let file = try? await repository.indexFile(path: path) else { return "" }
            return EditorWorkspace.readerText(file.data) ?? ""
        }
        switch diff.area {
        case .staged:
            let head = (try? await repository.headFileText(path: diff.file.originalPath ?? path)) ?? nil
            return (MarkdownDiffPage.normalized(head ?? ""), await indexText())
        default:
            let base = diff.file.isUntracked ? "" : await indexText()
            let url = root.appendingPathComponent(path)
            let current = await Task.detached(priority: .userInitiated) { () -> String in
                (try? Data(contentsOf: url)).flatMap(EditorWorkspace.readerText) ?? ""
            }.value
            return (base, current)
        }
    }
}

/// The rendered form of one Markdown file's diff.
struct MarkdownDiffView: View {
    let model: FolmiModel
    let diff: FileDiff
    @State private var page: MarkdownDiffPage.Page?
    @State private var failed = false

    var body: some View {
        let _ = PerfLog.body("MarkdownDiffView")
        ZStack {
            if let page {
                StaticReaderView(html: page.html, marks: page.marks, olds: page.olds, theme: model.theme,
                                 presentation: model.editorPresentation, root: model.repositoryURL)
            } else if failed {
                Text("无法读取这份文件的两个版本，请切到「源码」查看。").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: "\(diff.area)\0\(diff.file.path)\0\(diff.fingerprint)") {
            guard let texts = await model.markdownDiffTexts(diff) else { failed = true; return }
            let path = diff.file.path
            let built = await Task.detached(priority: .userInitiated) {
                MarkdownDiffPage.build(path: path, base: texts.base, current: texts.current)
            }.value
            guard !Task.isCancelled else { return }
            page = built
        }
    }
}
