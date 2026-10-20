import AppKit
import SwiftUI
import FolmiCore

/// A bounded, display-only projection. Original patches and selection IDs stay
/// untouched, and any omitted content disables partial operations for the file.
enum SideBySideDisplayBudget {
    /// Rows are drawn by an AppKit canvas that only paints what is visible, so the cap only guards memory.
    static let maximumRows = 100_000
    static let maximumLineUTF16 = 4_096

    struct HunkSection: Identifiable {
        let hunk: DiffHunk
        let rows: [AlignedDiffRow]
        var id: String { hunk.id }
    }

    struct Plan {
        let sections: [HunkSection]
        let untrackedRows: [AlignedDiffRow]
        let fallbackText: String
        let rowsLimited: Bool
        let textLimited: Bool
        let partialAllowed: Bool
        var maximumRows = SideBySideDisplayBudget.maximumRows
        var displayedRowCount: Int { sections.reduce(0) { $0 + $1.rows.count } + untrackedRows.count }
        var isLimited: Bool { rowsLimited || textLimited }
        var notice: String? {
            guard isLimited else { return nil }
            return "预览上限：每文件最多 \(maximumRows) 行、每行最多 4096 个 UTF-16 单元。部分内容已省略；此文件的选行和整块操作已停用，请使用整文件操作或编辑器查看。"
        }
    }

    @MainActor private static var cache: [String: Plan] = [:]
    @MainActor private static var cacheOrder: [String] = []

    /// The view re-renders on every selection click; aligning a large hunk again each time would stall it.
    @MainActor static func cachedPlan(for diff: FileDiff) -> Plan {
        let key = diff.area.rawValue + "\0" + diff.file.path + "\0" + diff.fingerprint
        if let plan = cache[key] { return plan }
        let plan = plan(for: diff)
        cache[key] = plan
        cacheOrder.append(key)
        if cacheOrder.count > 64 { cache[cacheOrder.removeFirst()] = nil }
        return plan
    }

    static func plan(for diff: FileDiff, maximumRows: Int = maximumRows) -> Plan {
        var sections: [HunkSection] = []
        var untrackedRows: [AlignedDiffRow] = []
        var fallbackText = ""
        var rowsLimited = false
        var textLimited = false
        var remaining = maximumRows

        if !diff.hunks.isEmpty {
            for hunk in diff.hunks {
                guard remaining > 0, sections.count < maximumRows else {
                    rowsLimited = true
                    break
                }
                let bounded = boundedHunk(hunk, maximumRows: remaining)
                rowsLimited = rowsLimited || bounded.limited
                textLimited = textLimited || clippedText(hunk.header).limited
                for row in bounded.rows {
                    if let old = row.old { textLimited = textLimited || clippedText(old.line.text).limited }
                    if let new = row.new { textLimited = textLimited || clippedText(new.line.text).limited }
                }
                sections.append(HunkSection(hunk: hunk, rows: bounded.rows))
                remaining -= bounded.rows.count
                if bounded.limited { break }
            }
        } else {
            // Do not components(separatedBy:) a 1 MiB file with a million empty
            // lines. Only materialize the bounded prefix of display lines.
            let preview = boundedText(diff.rawPatch, maximumRows: maximumRows)
            rowsLimited = preview.rowsLimited
            textLimited = preview.textLimited
            if diff.file.isUntracked, diff.notice?.contains("二进制") != true {
                untrackedRows = preview.lines.enumerated().map { position, text in
                    AlignedDiffRow(id: position, old: nil,
                                   new: AlignedDiffCell(line: DiffLine(id: position, text: text, kind: .addition), lineNumber: position + 1))
                }
            } else { fallbackText = preview.lines.joined(separator: "\n") }
        }

        return Plan(sections: sections, untrackedRows: untrackedRows, fallbackText: fallbackText,
                    rowsLimited: rowsLimited, textLimited: textLimited,
                    partialAllowed: diff.isPartialSupported && !rowsLimited && !textLimited, maximumRows: maximumRows)
    }

    /// Returns valid Unicode and includes the ellipsis in the UTF-16 budget.
    static func clippedText(_ text: String) -> (text: String, limited: Bool) {
        func clip(_ input: String) -> (String, Bool) {
            var units = Array(input.utf16.prefix(maximumLineUTF16 + 1))
            guard units.count > maximumLineUTF16 else { return (input, false) }
            units = Array(units.prefix(maximumLineUTF16 - 1))
            if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
            return (String(decoding: units, as: UTF16.self) + "…", true)
        }
        let first = clip(text)
        let expanded = clip(first.0.replacingOccurrences(of: "\t", with: "    "))
        return (expanded.0, first.1 || expanded.1)
    }

    private static func boundedHunk(_ hunk: DiffHunk, maximumRows: Int) -> (rows: [AlignedDiffRow], limited: Bool) {
        // Each side contributes at most one source token to a rendered row.
        // Keep that many tokens per side, continuing to scan a long change block
        // so its first additions can still pair with its first deletions. Stop
        // at the next context boundary once either side fills the budget.
        var kept: [DiffLine] = []
        var oldTokens = 0, newTokens = 0
        var previous = DiffLineKind.context
        var limited = false
        scan: for line in hunk.lines {
            switch line.kind {
            case .context:
                guard oldTokens < maximumRows, newTokens < maximumRows else { limited = true; break scan }
                kept.append(line); oldTokens += 1; newTokens += 1
                previous = .context
            case .deletion:
                if oldTokens < maximumRows { kept.append(line); oldTokens += 1 } else { limited = true }
                previous = .deletion
            case .addition:
                if newTokens < maximumRows { kept.append(line); newTokens += 1 } else { limited = true }
                previous = .addition
            case .meta:
                if previous == .deletion {
                    if oldTokens < maximumRows { kept.append(line); oldTokens += 1 } else { limited = true }
                } else if previous == .addition {
                    if newTokens < maximumRows { kept.append(line); newTokens += 1 } else { limited = true }
                } else {
                    guard oldTokens < maximumRows, newTokens < maximumRows else { limited = true; break scan }
                    kept.append(line); oldTokens += 1; newTokens += 1
                }
            }
        }
        let projected = DiffHunk(id: hunk.id, header: hunk.header, lines: kept)
        let aligned = DiffAlignment.rows(in: projected)
        return (Array(aligned.prefix(maximumRows)), limited || aligned.count > maximumRows)
    }

    private static func boundedText(_ text: String, maximumRows: Int) -> (lines: [String], rowsLimited: Bool, textLimited: Bool) {
        var lines: [String] = []
        var cursor = text.startIndex
        var textLimited = false
        while cursor < text.endIndex, lines.count < maximumRows {
            let end = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
            let clipped = clippedText(String(text[cursor..<end]))
            lines.append(clipped.text)
            textLimited = textLimited || clipped.limited
            cursor = end == text.endIndex ? end : text.index(after: end)
        }
        return (lines, cursor < text.endIndex, textLimited)
    }
}

struct SideBySideDiff: View {
    let diffs: [FileDiff]
    let selectedLines: [String: Set<Int>]
    let busy: Bool
    let onToggleLine: (Int, FileDiff) -> Void
    let onApplyHunk: (DiffHunk, FileDiff) -> Void
    let onApplySelection: (DiffHunk, FileDiff) -> Void
    let onStageFile: (FileChange) -> Void
    let onUnstageFile: (FileChange) -> Void
    let onEditFile: (String) -> Void
    var comments: [ReviewComment] = []
    var onComment: (String, DiffHunk, FileDiff) -> Void = { _, _, _ in }
    var onDeleteComment: (UUID) -> Void = { _ in }
    var onExplain: ((DiffHunk, FileDiff) -> Void)?
    var unified = false
    @Environment(\.folmiTheme) private var theme

    var body: some View {
        let _ = PerfLog.body("SideBySideDiff")
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diffs, id: \.file.path) { diff in
                        SideBySideFile(
                            diff: diff,
                            selected: selectedLines[diff.file.path] ?? [],
                            busy: busy,
                            columnWidth: max(180, (geometry.size.width - 1) / 2),
                            onToggleLine: onToggleLine,
                            onApplyHunk: onApplyHunk,
                            onApplySelection: onApplySelection,
                            onStageFile: onStageFile,
                            onUnstageFile: onUnstageFile,
                            onEditFile: onEditFile,
                            comments: comments.filter { $0.path == diff.file.path && $0.area == diff.area },
                            onComment: onComment,
                            onDeleteComment: onDeleteComment,
                            onExplain: onExplain,
                            unified: unified,
                            // One file on the page: a picture or document gets the page's height, not a fixed box.
                            previewHeight: diffs.count == 1 ? max(ChangePreview.defaultHeight, geometry.size.height - 170)
                                : ChangePreview.defaultHeight
                        )
                        .id(diff.area.rawValue + ":" + diff.file.path)
                    }
                }
            }
        }
        .background(Color.theme(theme, \.card))
    }
}

/// A distinct file view keeps repeated hunk identifiers in separate namespaces.
struct SideBySideFile: View {
    let diff: FileDiff
    let selected: Set<Int>
    let busy: Bool
    let columnWidth: CGFloat
    let onToggleLine: (Int, FileDiff) -> Void
    let onApplyHunk: (DiffHunk, FileDiff) -> Void
    let onApplySelection: (DiffHunk, FileDiff) -> Void
    let onStageFile: (FileChange) -> Void
    let onUnstageFile: (FileChange) -> Void
    let onEditFile: (String) -> Void
    let comments: [ReviewComment]
    let onComment: (String, DiffHunk, FileDiff) -> Void
    let onDeleteComment: (UUID) -> Void
    /// The all-changes page draws its own sticky header.
    var showsHeader = true
    var allowsLineSelection = true
    var currentHunkID: String?
    /// Hunks already reviewed: drawn quieter, with a check.
    var seenHunkIDs: Set<String> = []
    /// "解释": asks the AI card about this hunk.
    var onExplain: ((DiffHunk, FileDiff) -> Void)?
    /// The review page: ⏎ stages, so a hunk has no stage buttons, and 解释 / 评论 show only on the current hunk or
    /// under the pointer instead of on every hunk.
    var quietHunkActions = false
    /// Namespaces hunk scroll anchors when the same file appears as staged and unstaged.
    var anchorPrefix = ""
    /// Lets the all-changes page open a hunk's comment box from the keyboard; the hunk ID whose box is open.
    var commenting: Binding<String?>?
    /// A committed change: no staging or comment controls, and the sides are named by `sideTitles`.
    var readOnly = false
    var sideTitles: (old: String, new: String)?
    /// One column instead of old | new.
    var unified = false
    /// How tall a picture or document preview is drawn; the single-file views give it the room they have.
    var previewHeight: CGFloat = ChangePreview.defaultHeight
    /// Reports where the current hunk sits in the all-changes scroll view as it scrolls.
    var onCurrentFrame: ((CGRect) -> Void)?
    @Environment(\.folmiTheme) private var theme
    @State private var localCommenting: String?
    @State private var hoveredHunk: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var commentingHunk: String? {
        get { commenting?.wrappedValue ?? localCommenting }
        nonmutating set { if let commenting { commenting.wrappedValue = newValue } else { localCommenting = newValue } }
    }

    var body: some View {
        let _ = PerfLog.body("SideBySideFile")
        let display = SideBySideDisplayBudget.cachedPlan(for: diff)
        let preview = previewKind(display)
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(diff.file.path)
                        .themedFont(.system(size: 12, weight: .semibold, design: .monospaced), points: 12)
                        .lineLimit(1).truncationMode(.middle).help(diff.file.path)
                    Text("左右对照 · 两侧可分别横向滚动")
                        .themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("编辑") { onEditFile(diff.file.path) }.disabled(busy)
                Button(diff.area == .working ? "暂存文件" : "取消暂存") {
                    if diff.area == .working { onStageFile(diff.file) }
                    else { onUnstageFile(diff.file) }
                }.disabled(busy)
            }
            .controlSize(.small).padding(10)
            .background(Color.theme(theme, \.header))
            }

            if let notice = diff.notice {
                Label(notice, systemImage: "info.circle")
                    .themedFont(.caption, points: 10).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            if let notice = display.notice {
                Label(notice, systemImage: "text.badge.minus")
                    .themedFont(.caption, points: 10).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }

            if !comments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(comments) { comment in ReviewCommentRow(comment: comment) { onDeleteComment(comment.id) } }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }

            if preview == nil {
            HStack(spacing: 0) {
                let old = oldTitle, new = newTitle
                if unified {
                    HStack(spacing: 6) {
                        Circle().fill(.themed(.removed, opacity: 0.65)).frame(width: 5, height: 5)
                        Text(old).themedFont(.caption.weight(.medium), points: 10)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Circle().fill(.themed(.added, opacity: 0.65)).frame(width: 5, height: 5)
                        Text(new).themedFont(.caption.weight(.medium), points: 10)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 10)
                } else {
                    sideTitle(old, token: .removed)
                    Divider()
                    sideTitle(new, token: .added)
                }
            }
            .frame(height: 28)
            .background(Color.theme(theme, \.header).opacity(0.7))
            }

            if !diff.hunks.isEmpty {
                ForEach(display.sections) { section in
                    let seen = seenHunkIDs.contains(section.hunk.id)
                    VStack(alignment: .leading, spacing: 0) {
                        hunkToolbar(section.hunk, partialAllowed: display.partialAllowed)
                            .id(anchorPrefix + section.hunk.id)
                        DiffRowsView(rows: section.rows, rowsKey: diff.fingerprint + "\0" + section.id + "\0\(section.rows.count)",
                                     selected: selected, canSelect: allowsLineSelection && display.partialAllowed && !busy,
                                     unified: unified, onToggle: { onToggleLine($0, diff) })
                            .frame(height: DiffCanvasMetrics.height(rows: DiffRowsCanvas.displayCount(section.rows, unified: unified)))
                            .opacity(seen && currentHunkID != section.hunk.id ? 0.55 : 1)
                    }
                    .background {
                        if let onCurrentFrame, currentHunkID == section.hunk.id {
                            Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ReviewViewport.space)) } action: { onCurrentFrame($0) }
                        }
                    }
                }
            } else if diff.file.isUntracked, !diff.rawPatch.isEmpty,
                      diff.notice?.contains("二进制") != true {
                DiffRowsView(rows: display.untrackedRows, rowsKey: diff.fingerprint + "\0untracked\0\(display.untrackedRows.count)",
                             selected: [], canSelect: false, unified: unified, onToggle: { _ in })
                    .frame(height: DiffCanvasMetrics.height(rows: display.untrackedRows.count))
            } else if let preview, let versions = diff.versions {
                ChangePreview(path: diff.file.path, kind: preview, versions: versions, revision: diff.fingerprint,
                              oldTitle: oldTitle, newTitle: newTitle, unified: unified, height: previewHeight)
                    .background(Color.theme(theme, \.header).opacity(0.35))
            } else {
                Text(display.fallbackText.isEmpty ? "没有可显示的文本差异" : display.fallbackText)
                    .themedFont(.system(size: 12, design: .monospaced), points: 12)
                    .textSelection(.enabled).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().padding(.bottom, 14)
        }
    }

    private var oldTitle: String { sideTitles?.old ?? (diff.area == .working ? "暂存区（旧）" : "HEAD（旧）") }
    private var newTitle: String { sideTitles?.new ?? (diff.area == .working ? "工作区（新）" : "暂存区（新）") }

    /// Pictures, Word, PDF… with no text diff are shown as themselves, before and after.
    private func previewKind(_ display: SideBySideDisplayBudget.Plan) -> FilePreviewKind? {
        guard diff.versions != nil, diff.hunks.isEmpty, display.untrackedRows.isEmpty,
              diff.isBinary || diff.file.isUntracked else { return nil }
        return FilePreviewKind(path: diff.file.path)
    }

    private func sideTitle(_ title: String, token: ThemeToken) -> some View {
        HStack(spacing: 6) {
            Circle().fill(.themed(token, opacity: 0.65)).frame(width: 5, height: 5)
            Text(title).themedFont(.caption.weight(.medium), points: 10)
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).frame(width: columnWidth, alignment: .leading)
    }

    private func hunkToolbar(_ hunk: DiffHunk, partialAllowed: Bool) -> some View {
        let count = hunk.lines.filter { selected.contains($0.id) && ($0.kind == .addition || $0.kind == .deletion) }.count
        return HStack(spacing: 8) {
            if seenHunkIDs.contains(hunk.id) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.themed(.added)).help("已看过")
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else if !readOnly && !seenHunkIDs.isEmpty {
                Text("新").themedFont(.system(size: 9, weight: .bold), points: 9).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1).themedCapsule(ThemeColor(token: .accent)).help("上次看过之后的新改动")
            }
            Text(SideBySideDisplayBudget.clippedText(hunk.header).text).themedFont(.system(size: 10, design: .monospaced), points: 10)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            let actionsShown = !quietHunkActions || currentHunkID == hunk.id || hoveredHunk == hunk.id || commentingHunk == hunk.id
            if actionsShown, let onExplain {
                Button("解释") { onExplain(hunk, diff) }.help("让 AI 用几句话说明这处改了什么、有没有风险")
            }
            if !readOnly && actionsShown {
            Button(count > 0 ? "评论选中 \(count) 行" : "评论此块") { commentingHunk = hunk.id }
                .help("写一条审查评论，之后可一次性发送到终端")
                .popover(isPresented: Binding(get: { commentingHunk == hunk.id }, set: { if !$0 { commentingHunk = nil } }), arrowEdge: .bottom) {
                    ReviewCommentComposer(title: "\(diff.file.path) · \(count > 0 ? "选中 \(count) 行" : "整块")",
                                          onAdd: { onComment($0, hunk, diff); commentingHunk = nil },
                                          onCancel: { commentingHunk = nil })
                    .buttonStyle(ThemedDefaultButtonStyle())
                }
            if !quietHunkActions {
            Group {
                if count > 0 {
                    Button("\(diff.area == .working ? "暂存" : "取消暂存")选中 \(count) 行") {
                        onApplySelection(hunk, diff)
                    }.buttonStyle(.folmiProminent)
                }
                Button(diff.area == .working ? "暂存此块" : "取消暂存此块") { onApplyHunk(hunk, diff) }
            }
            .disabled(busy || !partialAllowed)
            }
            }
        }
        .controlSize(.mini)
        // The check pops in once ⏎ went through, and the current mark fades over to the next hunk instead of jumping.
        .animation(reduceMotion ? nil : Motion.settle, value: seenHunkIDs.contains(hunk.id))
        .animation(reduceMotion ? nil : Motion.state, value: currentHunkID == hunk.id)
        .onHover { inside in
            guard quietHunkActions else { return }
            if inside { hoveredHunk = hunk.id } else if hoveredHunk == hunk.id { hoveredHunk = nil }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(ThemeColor(token: .accent, opacity: currentHunkID == hunk.id ? 0.16 : 0.06))
        .overlay(alignment: .leading) {
            if currentHunkID == hunk.id { Rectangle().fill(ThemeColor(token: .accent)).frame(width: 3) }
        }
    }

}
