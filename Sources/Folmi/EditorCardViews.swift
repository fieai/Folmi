import SwiftUI
import AppKit
import FolmiCore

/// The editor card's frame. Its tab row, comment menu and page are separate views, so an editor tab change
/// re-renders the tab row and the tree selection, not the page under them.
struct EditorCard: View {
    let model: FolmiModel
    let tracker: PaneFocusTracker

    var body: some View {
        let _ = PerfLog.body("EditorCard")
        folmiCard(.editor, model: model, tracker: tracker) {
            EditorCardTabs(model: model)
        } accessory: {
            ReviewCommentsMenu(model: model)
        } content: {
            EditorCardPage(model: model)
        }
    }
}

struct EditorCardTabs: View {
    let model: FolmiModel
    var body: some View {
        let _ = PerfLog.body("EditorCardTabs")
        ContentModeSwitcher(model: model)
        if let modeDetail {
            // The switcher already names the mode; only its detail is added.
            Text(modeDetail).themedFont(.system(size: 12), points: 12).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 4)
        }
    }
    private var modeDetail: String? {
        switch model.content {
        case .diff: return model.fileDiffs.isEmpty ? nil : "\(model.fileDiffs.count) 个文件"
        case .allChanges: return model.snapshot.map { "\($0.files.count) 个文件" }
        default: return nil
        }
    }
}

/// Stable, named navigation; document tabs occupy their own row below it.
struct ContentModeSwitcher: View {
    let model: FolmiModel
    @Namespace private var fill
    private static let modes: [(FolmiContent, String, String)] = [
        (.editor, "doc.text", "编辑（打开的文件）"), (.diff, "plus.forwardslash.minus", "差异（左侧选中的改动）"),
        (.allChanges, "checklist", "全部改动（逐处验收）"), (.history, "clock", "历史（提交记录）")]

    var body: some View {
        let _ = PerfLog.body("ContentModeSwitcher")
        ViewThatFits(in: .horizontal) {
            navigation(showTitles: true)
            navigation(showTitles: false)
        }
    }

    private func navigation(showTitles: Bool) -> some View {
        HStack(spacing: 1) {
            ForEach(Self.modes, id: \.0) { mode, symbol, help in
                let selected = model.content == mode
                Button { model.showContent(mode) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: symbol).font(.system(size: Metrics.iconSize, weight: .medium))
                        if showTitles || selected {
                            Text(mode.rawValue).themedFont(.system(size: 12, weight: .medium), points: 12).fixedSize()
                        }
                    }
                    .foregroundStyle(ThemeColor(token: selected ? .foreground : .secondaryText))
                    .padding(.horizontal, 7).frame(height: Metrics.iconButton)
                    .background {
                        if selected { SegmentThumb().matchedGeometryEffect(id: "mode", in: fill) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help(help)
                .accessibilityLabel(mode.rawValue)
            }
        }
        .segmentTrack()
        .motion(Motion.state, value: model.content)
        .fixedSize()
    }
}

struct ReviewCommentsMenu: View {
    let model: FolmiModel
    var body: some View {
        let _ = PerfLog.body("ReviewCommentsMenu")
        let comments = model.currentReviewComments
        if !comments.isEmpty {
            let sendable = comments.filter { !$0.outdated }, outdated = comments.filter(\.outdated)
            Menu {
                Group {
                    Button("发送到终端（不回车）", action: model.sendReviewCommentsToTerminal)
                    Button("复制到剪贴板", action: model.copyReviewComments)
                }
                .disabled(sendable.isEmpty)
                Divider()
                ForEach(sendable) { comment in
                    Button("删除 \(comment.reference) · \(comment.body.prefix(24))") { model.deleteReviewComment(comment.id) }
                }
                if !outdated.isEmpty {
                    Section("已过时（不会发送）") {
                        ForEach(outdated) { comment in
                            Button("删除 \(comment.reference) · \(comment.body.prefix(24))") { model.deleteReviewComment(comment.id) }
                        }
                        Button("清除 \(outdated.count) 条已过时评论", action: model.clearOutdatedReviewComments)
                    }
                }
                Divider()
                Button("清空全部评论", role: .destructive, action: model.clearReviewComments)
            } label: {
                Label(sendable.isEmpty ? "\(outdated.count) 条评论已过时" : "发送 \(sendable.count) 条评论"
                      + (outdated.isEmpty ? "" : "（\(outdated.count) 条已过时）"), systemImage: "text.bubble")
            } primaryAction: { model.sendReviewCommentsToTerminal() }
            .menuStyle(.borderedButton).controlSize(.small).fixedSize()
            .help("把审查评论粘贴到本项目终端，不按回车（⌥⌘↩）")
        }
    }
}

struct EditorCardPage: View {
    let model: FolmiModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let _ = PerfLog.body("EditorCardPage")
        VStack(spacing: 0) {
            if model.content == .editor, let editor = model.editorWorkspace {
                HStack {
                    EditorTabStrip(workspace: editor, onSave: model.fileDidSave).id(editor.root.path)
                }.frame(height: Metrics.paneHeader).folmiSurface(.navigation)
                Divider()
            }
        // Switching 编辑 / 差异 / 全部改动 / 历史 cross-fades; the pages stay the same views otherwise.
        ZStack {
            if model.content == .editor, let editor = model.editorWorkspace {
                FileEditorPane(workspace: editor, onSave: model.fileDidSave).id(editor.root.path).transition(.opacity)
            } else if model.content == .allChanges {
                AllChangesView(model: model).id(model.repositoryURL?.path).transition(.opacity)
            } else if model.content == .history {
                HistoryView(model: model).id(model.repositoryURL?.path).transition(.opacity)
            } else { DiffPane(model: model).transition(.opacity) }
        }
        .animation(reduceMotion ? nil : Motion.state, value: model.content)
        }
    }
}

struct DiffPane: View {
    let model: FolmiModel
    var body: some View {
        let _ = PerfLog.body("DiffPane")
        Group {
            if model.fileDiffs.isEmpty {
                if model.snapshot?.files.isEmpty == true { DoneState(model: model) }
                else { panePlaceholder(symbol: "rectangle.split.2x1", title: "没有待比较的改动", detail: "选择左侧改动文件查看左右 diff；支持多选。") }
            } else {
                VStack(spacing: 0) {
                    DiffToolbar(model: model, diff: model.fileDiffs.count == 1 ? model.fileDiffs.first : nil)
                    Divider()
                    if let diff = renderedMarkdown {
                        MarkdownDiffView(model: model, diff: diff)
                    } else {
                        sourceDiff
                    }
                }
                .assistBeside(model)
            }
        }.background(Color.theme(model.theme, \.card))
    }
    private var sourceDiff: some View {
                SideBySideDiff(diffs: model.fileDiffs, selectedLines: model.selectedLines, busy: model.busy,
                               onToggleLine: { model.toggleLine($0, in: $1) },
                               onApplyHunk: { model.applyHunk($0, in: $1) },
                               onApplySelection: { model.applySelectedLines($0, in: $1) },
                               onStageFile: model.stageFile, onUnstageFile: model.unstageFile, onEditFile: model.editPath,
                               comments: model.currentReviewComments,
                               onComment: { model.addReviewComment($0, hunk: $1, in: $2) },
                               onDeleteComment: model.deleteReviewComment,
                               onExplain: model.explainHunk, unified: model.unifiedDiff)
    }
    /// One Markdown file, shown rendered unless the user switched this view to source.
    private var renderedMarkdown: FileDiff? {
        guard model.markdownDiffRendered, model.fileDiffs.count == 1, let diff = model.fileDiffs.first,
              EditorWorkspace.isMarkdownPath(diff.file.path), !diff.rawPatch.contains("Binary files ") else { return nil }
        return diff
    }
}

/// Above a single file's diff: how it is shown (渲染 / 源码 for Markdown), and the whole-file actions the rendered
/// view has no hunk buttons for.
struct DiffToolbar: View {
    let model: FolmiModel
    /// The one file shown, or nil when several are selected.
    let diff: FileDiff?
    private var rendered: Bool { model.markdownDiffRendered && diff.map { EditorWorkspace.isMarkdownPath($0.file.path) } == true }
    var body: some View {
        let _ = PerfLog.body("DiffToolbar")
        HStack(spacing: 8) {
            if let diff {
                Text(diff.file.path).themedFont(.system(size: 12, weight: .medium), points: 12).lineLimit(1).truncationMode(.middle)
                Text(diff.area == .staged ? "已暂存" : "工作区").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            } else {
                Text("\(model.fileDiffs.count) 个文件").themedFont(.system(size: 12, weight: .medium), points: 12)
            }
            Spacer(minLength: 8)
            if diff == nil, model.fileDiffs.count > 1 {
                Button(model.area == .staged ? "取消暂存这 \(model.fileDiffs.count) 个文件" : "暂存这 \(model.fileDiffs.count) 个文件",
                       action: model.toggleStageSelectedFiles)
                    .controlSize(.small).disabled(model.busy)
            }
            if let diff, rendered {
                Button(diff.area == .staged ? "取消暂存" : "暂存文件") {
                    diff.area == .staged ? model.unstageFile(diff.file) : model.stageFile(diff.file)
                }.controlSize(.small).disabled(model.busy)
                Button("编辑") { model.editPath(diff.file.path) }.controlSize(.small)
            }
            if let diff, EditorWorkspace.isMarkdownPath(diff.file.path) {
                ThemedSegmented(options: [(true, "渲染"), (false, "源码")],
                                selection: Binding(get: { model.markdownDiffRendered }, set: { model.markdownDiffRendered = $0 }))
                    .controlSize(.small)
                .help("Markdown 改动按排版后的样子看，或看源码行")
            }
            if !rendered {
                ThemedSegmented(options: [(false, "并排"), (true, "统一")],
                                selection: Binding(get: { model.unifiedDiff }, set: { model.unifiedDiff = $0 }))
                    .controlSize(.small)
                .help("新旧左右并排，或合成一列（窄窗口更好读）")
            }
        }
        .padding(.horizontal, 12).frame(height: 34)
    }
}

struct TerminalCard: View {
    let model: FolmiModel
    let tracker: PaneFocusTracker
    @State private var renamingTerminal: TerminalSession?
    @State private var terminalName = ""

    var body: some View {
        let _ = PerfLog.body("TerminalCard")
        if let terminal = model.terminalSession {
            folmiCard(.terminal, model: model, tracker: tracker) {
                let titles = TerminalSession.distinctTitles(model.terminalTabs.map(\.displayTitle))
                PaneTabGroup {
                    ForEach(Array(model.terminalTabs.enumerated()), id: \.element.id) { index, session in
                        TerminalTabButton(session: session, title: titles[index], selected: session === terminal && !model.aiTabSelected,
                                          select: { model.selectTerminalTab(session.id) },
                                          rename: { terminalName = session.name; renamingTerminal = session },
                                          close: { model.closeTerminalTab(session.id) })
                    }
                    PaneTab(title: "AI", selected: model.aiTabSelected) { model.openAgentTab() }
                }
            } accessory: {
                PaneIconButton(symbol: "text.bubble", help: "说人话：把终端里选中的内容讲明白") {
                    if let text = model.terminalSelection, !text.isEmpty { model.assist(.plain, text: text, source: "终端选中内容") }
                    else { NSSound.beep() }
                }
                PaneIconButton(symbol: "plus", help: "新建终端标签（⌃⇧`）", action: model.newTerminalTab)
                PaneIconButton(symbol: "arrow.counterclockwise", help: "重开这个终端（替换当前 shell）", action: model.restartTerminal)
            } content: {
                ZStack {
                    TerminalPane(session: terminal).id(terminal.id).opacity(model.aiTabSelected ? 0 : 1)
                        .allowsHitTesting(!model.aiTabSelected)
                    if model.aiTabSelected { AgentPane(model: model).background(Color.theme(model.theme, \.card)) }
                }
            }
            .alert("重命名终端标签", isPresented: Binding(get: { renamingTerminal != nil }, set: { if !$0 { renamingTerminal = nil } })) {
                TextField("例如 agent、测试", text: $terminalName)
                Button("确定") { if let session = renamingTerminal { model.renameTerminalTab(session.id, to: terminalName) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("留空则显示程序设置的标题。")
            }
        }
    }
}
