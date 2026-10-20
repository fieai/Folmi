import SwiftUI
import AppKit

/// One ATX heading. Ranges are UTF-16 and refer to the text it was read from.
struct MarkdownHeading: Equatable, Sendable {
    let level: Int
    let title: String
    /// 0-based line number.
    let line: Int
    /// The heading line without its newline.
    let range: NSRange
    /// Stable across edits elsewhere: level, title and how many identical headings come before it.
    let key: String
}

/// A document's headings and the section each one opens.
struct MarkdownSections: Equatable, Sendable {
    var headings: [MarkdownHeading] = []
    /// The body of each heading that has one, by index into `headings`: everything up to the next heading of the
    /// same or a higher level.
    var bodies: [Int: NSRange] = [:]
}

/// Headings and sections. Pure, so the outline, the reader and the editor agree.
enum MarkdownOutline {
    static let maximumHeadings = 5_000

    static func headings(_ text: String) -> [MarkdownHeading] {
        let source = text as NSString
        var result: [MarkdownHeading] = []
        var seen: [String: Int] = [:]
        var fence: (character: unichar, count: Int)?
        var location = 0, line = 0
        while location < source.length, result.count < maximumHeadings {
            var end = location
            while end < source.length, source.character(at: end) != 10, source.character(at: end) != 13 { end += 1 }
            var next = end
            if next < source.length, source.character(at: next) == 13 { next += 1 }
            if next < source.length, source.character(at: next) == 10 { next += 1 }
            let content = NSRange(location: location, length: end - location)
            var start = location
            while start < min(end, location + 3), source.character(at: start) == 32 { start += 1 }
            let first = start < end ? source.character(at: start) : 0
            if first == 96 || first == 126 {
                var run = start
                while run < end, source.character(at: run) == first { run += 1 }
                let count = run - start
                if let open = fence {
                    if open.character == first, count >= open.count,
                       source.substring(with: NSRange(location: run, length: end - run)).trimmingCharacters(in: .whitespaces).isEmpty {
                        fence = nil
                    }
                } else if count >= 3 { fence = (first, count) }
            } else if fence == nil, first == 35 {
                var hashes = start
                while hashes < end, source.character(at: hashes) == 35 { hashes += 1 }
                let level = hashes - start
                if level <= 6, hashes == end || [32, 9].contains(source.character(at: hashes)) {
                    var title = source.substring(with: NSRange(location: hashes, length: end - hashes)).trimmingCharacters(in: .whitespaces)
                    // An optional closing run of #, when separated by a space.
                    if title.hasSuffix("#"), let closing = title.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
                        title = String(title[..<closing.lowerBound]).trimmingCharacters(in: .whitespaces)
                    }
                    let base = "\(level)|\(title)"
                    let ordinal = seen[base, default: 0]
                    seen[base] = ordinal + 1
                    result.append(MarkdownHeading(level: level, title: title, line: line, range: content, key: "\(base)|\(ordinal)"))
                }
            }
            location = next; line += 1
        }
        return result
    }

    /// The index of the heading whose section holds `location`.
    static func currentIndex(_ headings: [MarkdownHeading], at location: Int) -> Int? {
        // Headings are in document order: binary search for the last one starting at or before `location`.
        var low = 0, high = headings.count
        while low < high {
            let middle = (low + high) / 2
            if headings[middle].range.location <= location { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    static func layout(_ text: String) -> MarkdownSections {
        let length = (text as NSString).length
        var layout = MarkdownSections(headings: headings(text))
        let all = layout.headings
        // One pass with a stack of open sections: a heading closes every open one of the same or a deeper level.
        func close(_ index: Int, at end: Int) {
            let start = min(length, NSMaxRange(all[index].range) + 1)
            // A body ends with its newline, so the next heading starts a fresh line.
            if end > start { layout.bodies[index] = NSRange(location: start, length: end - start) }
        }
        var open: [Int] = []
        for (index, heading) in all.enumerated() {
            while let last = open.last, all[last].level >= heading.level { close(last, at: heading.range.location); open.removeLast() }
            open.append(index)
        }
        for index in open { close(index, at: length) }
        return layout
    }
}

/// `[[note]]`, `[[note#heading]]` and `[[note|shown text]]`.
enum MarkdownWiki {
    /// Finds the project file a wiki name points to: a Markdown note (or a file, when the name has an extension) with
    /// that name, preferring the document's own folder, then the shortest path.
    static func match(_ rawName: String, from documentPath: String, in paths: [String]) -> String? {
        var name = rawName.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix("/") { name.removeFirst() }
        guard !name.isEmpty else { return nil }
        let hasExtension = !(name as NSString).pathExtension.isEmpty && !(name as NSString).pathExtension.contains(" ")
        let wanted = hasExtension ? [name.lowercased()] : ["md", "markdown"].map { (name + "." + $0).lowercased() }
        let directory = (documentPath as NSString).deletingLastPathComponent
        let candidates = paths.filter { path in
            let lower = path.lowercased()
            return wanted.contains { lower == $0 || lower.hasSuffix("/" + $0) }
        }
        return candidates.min { a, b in
            let aLocal = (a as NSString).deletingLastPathComponent == directory
            let bLocal = (b as NSString).deletingLastPathComponent == directory
            if aLocal != bLocal { return aLocal }
            let aDepth = a.split(separator: "/").count, bDepth = b.split(separator: "/").count
            if aDepth != bDepth { return aDepth < bDepth }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// Names to offer after `[[`: each note by its file name, or by its path when two notes share a name.
    static func names(_ paths: [String], matching partial: String, limit: Int = 40) -> [String] {
        let notes = paths.filter { ["md", "markdown"].contains(($0 as NSString).pathExtension.lowercased()) }
        let base = { (path: String) in ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        var counts: [String: Int] = [:]
        for path in notes { counts[base(path).lowercased(), default: 0] += 1 }
        let names = notes.map { counts[base($0).lowercased()]! > 1 ? ($0 as NSString).deletingPathExtension : base($0) }
        let needle = partial.lowercased()
        let ranked = names.compactMap { name -> (Int, String)? in
            let lower = name.lowercased()
            if needle.isEmpty { return (1, name) }
            if lower.hasPrefix(needle) || base(name).lowercased().hasPrefix(needle) { return (0, name) }
            return lower.contains(needle) ? (1, name) : nil
        }
        return ranked.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1.count != $1.1.count ? $0.1.count < $1.1.count : $0.1 < $1.1) }
            .prefix(limit).map(\.1)
    }

    /// The name typed so far after an open `[[` before the caret, as a range, or nil when the caret is not in one.
    static func partialRange(text: String, selection: NSRange) -> NSRange? {
        let source = text as NSString
        guard selection.length == 0, selection.location <= source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = source.substring(with: NSRange(location: line.location, length: selection.location - line.location)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else { return nil }
        let start = NSMaxRange(open)
        let typed = before.substring(from: start)
        guard !typed.contains(where: { "[]|#".contains($0) }) else { return nil }
        return NSRange(location: line.location + start, length: selection.location - line.location - start)
    }
}

extension EditorWorkspace {
    func revealHeading(_ heading: MarkdownHeading, in documentID: String) {
        try? reveal(path: documentID, range: NSRange(location: NSMaxRange(heading.range), length: 0))
    }

    // MARK: Wiki links

    /// Markdown and other project files, listed at most every few seconds while names are being completed.
    func wikiCandidatePaths() -> [String] {
        if let cached = wikiPathCache, Date().timeIntervalSince(cached.date) < 5 { return cached.paths }
        let paths = (try? filePaths()) ?? []
        wikiPathCache = (Date(), paths)
        return paths
    }

    func wikiNames(matching partial: String) -> [String] {
        MarkdownWiki.names(wikiCandidatePaths(), matching: partial)
    }

    /// Creates `name.md` beside `documentPath` with a title, and returns its path. Never overwrites a file.
    @discardableResult
    func createWikiNote(_ name: String, from documentPath: String) throws -> String {
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        let directory = (documentPath as NSString).deletingLastPathComponent
        let file = (trimmed as NSString).pathExtension.isEmpty ? trimmed + ".md" : trimmed
        let path = directory.isEmpty ? file : directory + "/" + file
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !trimmed.isEmpty, !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw FileEditorError.unsafePath
        }
        let url = root.appendingPathComponent(path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard (parent.resolvingSymlinksInPath().standardizedFileURL.path + "/").hasPrefix(base) else { throw FileEditorError.unsafePath }
        let title = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        do { try Data("# \(title)\n\n".utf8).write(to: url, options: .withoutOverwriting) }
        catch { throw FileEditorError.io(error.localizedDescription) }
        wikiPathCache = nil
        return path
    }

    /// ⌘-click on `[[name]]`: opens the note, or offers to create it beside the document.
    func followWikiLink(_ name: String, anchor: String?, from documentPath: String, confirmCreate: (String) -> Bool) {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            if let anchor { followLink("#" + anchor, from: documentPath) }
            return
        }
        wikiPathCache = nil
        var path = MarkdownWiki.match(name, from: documentPath, in: wikiCandidatePaths())
        if path == nil {
            guard confirmCreate(name) else { return }
            do { path = try createWikiNote(name, from: documentPath) }
            catch { errorMessage = "无法创建笔记「\(name)」：\(error.localizedDescription)"; return }
        }
        guard let path else { return }
        let encoded = path.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        followLink("/" + encoded + (anchor.map { "#" + $0 } ?? ""), from: documentPath)
    }
}

/// The outline's data for the selected Markdown document. Fed by a background scan of the source (or the reader)
/// and on caret moves, so the outline never scans the text while SwiftUI renders.
@MainActor
final class MarkdownOutlineModel: ObservableObject {
    @Published private(set) var documentID: String?
    @Published private(set) var headings: [MarkdownHeading] = []
    /// The heading whose section holds the caret.
    @Published private(set) var current: Int?
    private var caret = 0

    func update(documentID: String, layout: MarkdownSections, caret: Int) {
        if self.documentID != documentID { self.documentID = documentID }
        if headings != layout.headings { headings = layout.headings }
        updateCaret(caret)
    }

    func updateCaret(_ location: Int) {
        caret = location
        let index = MarkdownOutline.currentIndex(headings, at: location)
        if current != index { current = index }
    }
}

/// The outline beside a Markdown editor: click a heading to jump to it.
enum MarkdownOutlineWidth {
    static let minimum: Double = 160
    static let maximum: Double = 420
    /// Below this much room for the text, the outline hides itself.
    static let minimumEditor: CGFloat = 460
}

/// The outline's left edge. Dragging shows a guide line only; the width (and the editor's relayout) is applied once,
/// on release, so a long document is not rewrapped on every mouse move. The AppKit divider keeps the cursor steady.
struct MarkdownOutlineResizeHandle: View {
    @Binding var width: Double
    let available: CGFloat
    @State private var offset: CGFloat?
    @State private var proposedWidth: Double?

    var body: some View {
        let _ = PerfLog.body("MarkdownOutlineResizeHandle")
        PaneResizeHandle(axis: .horizontal, inverted: true, thickness: 7, value: { width },
                         limit: { _ in MarkdownOutlineWidth.minimum...Double(upper) },
                         onBegin: { proposedWidth = width },
                         onChange: { value in proposedWidth = value; offset = 3 + CGFloat(width - value) },
                         onEnd: {
                             if let proposedWidth { width = proposedWidth }
                             proposedWidth = nil; offset = nil
                         },
                         onReset: { width = 220 }, help: "拖动调整大纲宽度，双击恢复默认")
            .overlay(alignment: .leading) {
                if let offset { Rectangle().fill(ThemeColor(token: .accent)).frame(width: 2).offset(x: offset).allowsHitTesting(false) }
            }
            .offset(x: -3)
    }

    /// The outline stays within its limits and leaves the editor its minimum.
    private var upper: CGFloat {
        max(CGFloat(MarkdownOutlineWidth.minimum), min(CGFloat(MarkdownOutlineWidth.maximum), available - MarkdownOutlineWidth.minimumEditor))
    }
}

struct MarkdownOutlinePane: View, Equatable {
    @ObservedObject var outline: MarkdownOutlineModel
    /// Actions only; the pane does not observe the workspace, so typing does not re-render it.
    let workspace: EditorWorkspace
    let documentID: String
    @Environment(\.folmiTheme) private var theme

    nonisolated static func == (a: Self, b: Self) -> Bool { a.documentID == b.documentID }

    var body: some View {
        let _ = PerfLog.body("MarkdownOutlinePane")
        let headings = outline.documentID == documentID ? outline.headings : []
        let current = outline.documentID == documentID ? outline.current : nil
        let topLevel = headings.map(\.level).min() ?? 1
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("大纲").themedFont(.system(size: 11, weight: .semibold), points: 11).foregroundStyle(.themed(.tertiaryText))
                Spacer()
            }
            .buttonStyle(.pressable).foregroundStyle(.themed(.tertiaryText))
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            if headings.isEmpty {
                Text("没有标题").themedFont(.caption, points: 10).foregroundStyle(.secondary).padding(12)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(headings.enumerated()), id: \.offset) { index, heading in
                                row(heading, current: index == current, indent: heading.level - topLevel)
                                    .id(index)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: current) { _, value in if let value { proxy.scrollTo(value) } }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .folmiSurface(.navigation)
        .accessibilityIdentifier("markdown-outline")
    }

    private func row(_ heading: MarkdownHeading, current: Bool, indent: Int) -> some View {
        OutlineRow(heading: heading, current: current, indent: indent, reveal: { workspace.revealHeading(heading, in: documentID) })
    }
}

/// One heading in the outline: a quiet table-of-contents line. Depth shows as indent and weight; the current section
/// lights its piece of the rail on the left instead of filling the row.
private struct OutlineRow: View {
    let heading: MarkdownHeading
    let current: Bool
    let indent: Int
    let reveal: () -> Void
    @State private var hovering = false

    var body: some View {
        let depth = min(indent, 4)
        HStack(spacing: 2) {
            Color.clear.frame(width: 12, height: 14)
            Text(heading.title.isEmpty ? "（空标题）" : heading.title)
                .themedFont(.system(size: depth >= 2 ? 12 : 12.5, weight: current || depth == 0 ? .semibold : .regular), points: depth >= 2 ? 12 : 12.5)
                .foregroundStyle(ThemeColor(token: current ? .foreground : depth >= 2 ? .secondaryText : .foreground))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + CGFloat(depth) * 12).padding(.trailing, 8).padding(.vertical, 3.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedBackground(ThemeColor(token: .hover, opacity: hovering && !current ? 1 : 0))
        .background(alignment: .leading) {
            Rectangle().fill(ThemeColor(token: current ? .accent : .border, opacity: current ? 1 : 0.9))
                .frame(width: current ? 2 : 1).padding(.leading, current ? 0 : 0.5)
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: reveal)
        .onHover { hovering = $0 }
        .help(heading.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, reveal)
    }
}
