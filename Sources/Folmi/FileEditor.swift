import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit
import Darwin
import FolmiCore

struct FileEditorPane: View {
    @ObservedObject var workspace: EditorWorkspace
    var onSave: () -> Void
    @Environment(\.folmiTheme) private var theme
    @State private var syntaxStatus = "词法高亮"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = PerfLog.body("FileEditorPane")
        VStack(spacing: 0) {
            if workspace.documents.isEmpty {
                ContentUnavailableView("打开一个文件开始编辑", systemImage: "doc.text",
                                       description: Text("在项目文件列表中选择文件。编辑保留在各自标签中，保存后才能暂存。"))
            } else {
                HStack(spacing: 8) {
                    if isMarkdown {
                        ThemedSegmented(options: [(true, "阅读"), (false, "编辑")], selection: $workspace.markdownReading)
                            .controlSize(.small)
                        .help("阅读：排版后的文档，选中文字可发到终端。编辑：Markdown 源码。⇧⌥M 切换")
                    }
                    Text(workspace.selectedDocument?.path ?? "")
                        .themedFont(.caption.monospaced(), points: 10).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let notice = workspace.notice {
                        Text(notice).themedFont(.caption, points: 10).foregroundStyle(ThemeColor(token: .modified)).lineLimit(1).truncationMode(.tail).help(notice)
                            .transition(.opacity)
                    }
                    // Only what is used while working shows here; the rest is under ⋯.
                    if workspace.selectedDocument?.isDirty == true {
                        Button("保存") { saveSelected() }
                            .buttonStyle(.folmiProminent).controlSize(.small)
                            .help("保存（⌘S）")
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    if isMarkdown {
                        PaneIconToggle(symbol: "list.bullet.indent", isOn: $workspace.showsOutline,
                                       help: "大纲：点击标题跳转，当前一节在左边竖线上亮起")
                    }
                    if preview == nil {
                        PaneIconToggle(symbol: "return.left", isOn: $workspace.presentation.wrapLines, help: "自动换行")
                            .disabled(reading)
                        PaneIconButton(symbol: "magnifyingglass", help: reading ? "查找（⌘F）" : "查找 / 替换（⌘F）") { find() }
                    }
                    Menu {
                        Button("全部保存（⇧⌘S）") { perform { try workspace.saveAll(); onSave() } }
                            .disabled(!workspace.hasUnsavedChanges)
                        Divider()
                        if let preview {
                            Text(preview.title)
                        } else {
                            Text(isMarkdown ? "Markdown" : SyntaxLanguage(path: workspace.selectedDocument?.path ?? "").title)
                            Text(reading ? "阅读视图" : syntaxStatus)
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: Metrics.iconSize, weight: .medium))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                    .foregroundStyle(.secondary)
                    .help("更多：全部保存、语言与高亮说明。词法着色无外部依赖，每次最多扫描前 192 Ki 字符")
                    .accessibilityLabel("更多")
                }
                .motion(Motion.reveal, value: workspace.selectedDocument?.isDirty == true)
                .motion(Motion.reveal, value: workspace.notice)
                .background {
                    // Keyboard shortcuts stay on even when their buttons are tucked away.
                    Group {
                        Button("保存") { saveSelected() }.keyboardShortcut("s", modifiers: .command)
                            .disabled(workspace.selectedDocument?.isDirty != true)
                        Button("全部保存") { perform { try workspace.saveAll(); onSave() } }.keyboardShortcut("s", modifiers: [.command, .shift])
                            .disabled(!workspace.hasUnsavedChanges)
                    }
                    .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .folmiSurface(.navigation)
                Divider()
                if let document = workspace.selectedDocument {
                    GeometryReader { geometry in
                        let outlineWidth = CGFloat(workspace.outlineWidth)
                        // A narrow card gives the room to the text; the outline comes back once there is space again.
                        let fits = geometry.size.width - outlineWidth >= MarkdownOutlineWidth.minimumEditor
                        HStack(spacing: 0) {
                            // The notice takes its own row above the text, so it never covers the heading being read.
                            VStack(spacing: 0) {
                                if workspace.externalChanges[document.id] != nil {
                                    ExternalChangeBanner(onShowChanges: { workspace.showChanges?(document.path) },
                                                         onDismiss: { workspace.dismissExternalChange(document.id) })
                                        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }
                                // Both views stay alive for a Markdown file, so 阅读 / 编辑 is a cross-fade at the same
                                // place in the document rather than tearing one view down and loading the other.
                                ZStack {
                                    NativeCodeEditor(workspace: workspace, documentID: document.id, text: Binding(
                                        get: { workspace.documents.first { $0.id == document.id }?.text ?? "" },
                                        set: { workspace.updateText(id: document.id, text: $0) }
                                    ), syntaxStatus: $syntaxStatus)
                                    .opacity(reading || document.preview != nil ? 0 : 1)
                                    .allowsHitTesting(!reading && document.preview == nil)
                                    // Kept for code files too (rendering nothing), so coming back to a Markdown file does not
                                    // build and load a new web view.
                                    MarkdownReaderView(workspace: workspace, documentID: document.id, text: isMarkdown ? document.text : "",
                                                       presentation: workspace.presentation, theme: theme,
                                                       navigationRevision: workspace.navigationRevision, indexRevision: workspace.indexRevision,
                                                       active: reading, isMarkdown: isMarkdown,
                                                       externalChange: workspace.externalChanges[document.id])
                                    .opacity(reading ? 1 : 0)
                                    .allowsHitTesting(reading)
                                    if let kind = document.preview {
                                        FilePreviewView(url: workspace.root.appendingPathComponent(document.path), kind: kind,
                                                        revision: document.fingerprint,
                                                        onEditSource: FilePreviewKind.hasSource(document.path)
                                                            ? { perform { try workspace.open(path: document.path, asText: true) } } : nil)
                                        .id(document.id)
                                    }
                                }
                                .animation(reduceMotion ? nil : Motion.state, value: reading)
                            }
                            .animation(reduceMotion ? nil : Motion.state, value: workspace.externalChanges[document.id] != nil)
                            if isMarkdown && workspace.showsOutline && fits {
                                Divider()
                                MarkdownOutlinePane(outline: workspace.outline, workspace: workspace, documentID: document.id)
                                    .equatable()
                                    .frame(width: outlineWidth)
                                    .overlay(alignment: .leading) {
                                        MarkdownOutlineResizeHandle(width: $workspace.outlineWidth,
                                                                    available: geometry.size.width)
                                    }
                                    .transition(.paneSlide(edge: .trailing))
                            }
                        }
                        .animation(reduceMotion ? nil : Motion.layout, value: isMarkdown && workspace.showsOutline && fits)
                    }
                }
            }
        }
        .background(Color.theme(theme, \.card))
        // A preview tab has no text: the hidden editor behind it must not keep the keyboard (typing, ⌘F, ⌘A).
        .onChange(of: workspace.selectedDocumentID) { _, _ in
            guard preview != nil, let window = NSApp.keyWindow, window.firstResponder is EditorTextView else { return }
            window.makeFirstResponder(nil)
        }
        .alert("文件未保存", isPresented: Binding(
            get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { workspace.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? "") }
    }

    private var reading: Bool { isMarkdown && workspace.markdownReading }
    private var preview: FilePreviewKind? { workspace.selectedDocument?.preview }
    private var isMarkdown: Bool { ["md", "markdown", "mdown"].contains((workspace.selectedDocument?.path as NSString?)?.pathExtension.lowercased() ?? "") }
    private func saveSelected() { perform { try workspace.saveSelected(); onSave() } }
    private func find() {
        guard preview == nil else { return }
        if reading { workspace.openReaderFind?() }
        else { NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: FindPanelSender()) }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { workspace.errorMessage = error.localizedDescription }
    }
}

/// The open files as tabs, shown in the editor card's title strip so the card has one row of tabs, not two.
struct EditorTabStrip: View {
    @ObservedObject var workspace: EditorWorkspace
    var onSave: () -> Void
    @State private var closeDocumentID: String?
    @State private var showsClosePrompt = false
    @Namespace private var tabFill

    var body: some View {
        let _ = PerfLog.body("EditorTabStrip")
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.documents) { document in
                        let dirty = document.isDirty
                        EditorTabButton(path: document.path, isDirty: dirty, selected: workspace.selectedDocumentID == document.id,
                                        underline: tabFill,
                                        onSelect: { workspace.selectedDocumentID = document.id },
                                        onClose: {
                                            if dirty { closeDocumentID = document.id; showsClosePrompt = true }
                                            else { perform { try workspace.close(id: document.id) } }
                                        },
                                        onCloseTabs: { workspace.closeTabs($0, around: document.id) },
                                        fileURL: workspace.root.appendingPathComponent(document.path))
                        .equatable()
                        .id(document.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .leading)),
                                                removal: .opacity.combined(with: .scale(scale: 0.92, anchor: .leading))))
                    }
                }
                .padding(.horizontal, 2)
                .motion(Motion.state, value: workspace.documents.map(\.id))
                .motion(Motion.state, value: workspace.selectedDocumentID)
            }
            .onChange(of: workspace.selectedDocumentID) { _, id in
                guard let id else { return }
                withMotion(Motion.reveal) { proxy.scrollTo(id) }
            }
        }
        .confirmationDialog("这个文件还有未保存的改动", isPresented: $showsClosePrompt, titleVisibility: .visible) {
            Button("保存后关闭") {
                guard let id = closeDocumentID else { return }
                perform {
                    let previous = workspace.selectedDocumentID
                    workspace.selectedDocumentID = id
                    do { try workspace.saveSelected() }
                    catch { workspace.selectedDocumentID = previous; throw error }
                    try workspace.close(id: id)
                    onSave()
                }
                closeDocumentID = nil
            }
            Button("放弃改动并关闭", role: .destructive) {
                if let id = closeDocumentID { perform { try workspace.close(id: id, discard: true) } }
                closeDocumentID = nil
            }
            Button("取消", role: .cancel) { closeDocumentID = nil }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { workspace.errorMessage = error.localizedDescription }
    }
}

/// One editor tab: a dirty dot, the file name and a close button that shows on hover or for the selected tab.
/// The accent underline slides between tabs.
/// Compared by what it shows, not by its closures (which only capture the document id), so a keystroke or a switch
/// re-renders the tabs whose dot or selection changed rather than every tab.
private struct EditorTabButton: View, Equatable {
    let path: String
    let isDirty: Bool
    let selected: Bool
    let underline: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseTabs: (EditorWorkspace.TabCloseScope) -> Void
    let fileURL: URL

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.path == b.path && a.isDirty == b.isDirty && a.selected == b.selected && a.underline == b.underline && a.fileURL == b.fileURL
    }
    @State private var hovering = false
    @Environment(\.folmiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = PerfLog.body("EditorTabButton")
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 5) {
                    if isDirty {
                        Circle().fill(ThemeColor(token: .modified)).frame(width: 6, height: 6).transition(.scale.combined(with: .opacity))
                    }
                    Text((path as NSString).lastPathComponent).lineLimit(1)
                        .themedFont(.system(size: 12, weight: selected ? .medium : .regular), points: 12)
                        .foregroundStyle(ThemeColor(token: selected ? .foreground : .secondaryText))
                }
                .padding(.leading, 9).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16)
                    .themedBackground(ThemeColor(token: .hover, opacity: hovering ? 1 : 0), .control)
            }
            .buttonStyle(.pressable)
            .opacity(selected || hovering ? 1 : 0)
            .help("关闭 \(path)")
        }
        .padding(.trailing, 4)
        .background {
            // The selected tab's fill slides from tab to tab.
            if selected {
                TabBackground(selected: true).matchedGeometryEffect(id: "tabFill", in: underline)
            } else if hovering {
                TabBackground(selected: false, hovering: true)
            }
        }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.hover, value: hovering)
        .animation(reduceMotion ? nil : Motion.state, value: isDirty)
        .help(path)
        .contextMenu {
            Button("关闭", action: onClose)
            Button("关闭其他") { onCloseTabs(.others) }
            Button("关闭左侧") { onCloseTabs(.left) }
            Button("关闭右侧") { onCloseTabs(.right) }
            Button("关闭已保存") { onCloseTabs(.saved) }
            Button("关闭全部") { onCloseTabs(.all) }
            Divider()
            FileActionsMenu(url: fileURL, relativePath: path)
        }
    }
}

/// Path and Finder actions shared by the tab and file-tree menus.
struct FileActionsMenu: View {
    let url: URL
    let relativePath: String
    var body: some View {
        Button("复制路径") { Self.copy(url.path) }
        Button("复制相对路径") { Self.copy(relativePath) }
        Button("复制文件名") { Self.copy(url.lastPathComponent) }
        Divider()
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("用默认应用打开") { NSWorkspace.shared.open(url) }
    }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Shown over a document that another program (usually the agent in the terminal) just changed on disk.
struct ExternalChangeBanner: View {
    let onShowChanges: () -> Void
    let onDismiss: () -> Void
    var body: some View {
        let _ = PerfLog.body("ExternalChangeBanner")
        HStack(spacing: 10) {
            Circle().fill(ThemeColor(token: .accent)).frame(width: 7, height: 7)
            Text("这个文件刚被其他程序修改，已自动刷新").themedFont(.system(size: 12.5), points: 12.5)
            Spacer(minLength: 8)
            Button("查看改动", action: onShowChanges).buttonStyle(.themedLink).themedFont(.system(size: 12.5), points: 12.5)
            Button("知道了", action: onDismiss).buttonStyle(.pressable).foregroundStyle(.secondary).themedFont(.system(size: 12.5), points: 12.5)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .folmiSurface(.popover, cornerRadius: 10)
    }
}
