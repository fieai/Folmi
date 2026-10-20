import AppKit
import SwiftUI

@MainActor
final class FolmiAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: FolmiModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.prepareToQuit() == false ? .terminateCancel : .terminateNow
    }
}

@main
struct FolmiApp: App {
    @NSApplicationDelegateAdaptor(FolmiAppDelegate.self) private var delegate
    @State private var model = FolmiModel(autoRefresh: true, checkEnvironmentOnStartup: true)

    var body: some Scene {
        WindowGroup("Folmi") {
            FolmiView(model: model)
                .frame(minWidth: 1080, minHeight: 680)
                .task {
                    PerfLog.mark("launch.windowTask")
                    LocalCLI.warm()
                    InboxPanel.shared.register(model: model)
                    delegate.model = model
                    AINotifier.shared.start(model: model)
                    CommandHoldMonitor.shared.start(model: model)
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if !model.startupResumed { await model.checkGitEnvironment() }
                    if let sheet = RuntimeOptions.present, !model.gitStartupState.blocksGit {
                        while model.snapshot == nil || model.busy { try? await Task.sleep(for: .milliseconds(100)) }
                        try? await Task.sleep(for: .seconds(1))
                        model.present(sheet)
                    }
                    // WebKit takes ~0.3 s of the main thread to start; that waits until the first screen is up, unless
                    // the first screen is a Markdown document in reading mode (warmed above, beside the status read).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ReaderWebViewPool.warm() }
                    // The menu bar icon follows every project's status; plain `git status`, every two minutes.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                        if !model.gitStartupState.blocksGit { model.board.refresh(projects: model.projects) }
                        try? await Task.sleep(for: .seconds(115))
                    }
                }
                // `folmi://` links (MCP show_in_folmi) go to this window, not a new one.
                .onOpenURL { model.handleFolmiLink($0) }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1440, height: 900)
        .commands { FolmiCommands(model: model) }
        MenuBarExtra {
            MenuBarBoard(model: model)
        } label: {
            // The Folmi mark, with the number of projects that have changes beside it.
            HStack(spacing: 3) {
                if let mark = AppResources.menuBarMark { Image(nsImage: mark) } else { Image(systemName: "checkmark.circle") }
                if model.board.dirtyCount > 0 { Text("\(model.board.dirtyCount)") }
            }
                .accessibilityLabel(model.board.dirtyCount > 0 ? "Folmi：\(model.board.dirtyCount) 个项目有改动" : "Folmi：都收好了")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar commands, in their own type: what they read (busy, the open document, undo labels) re-renders the
/// menus only, not the window's scene every time the editor switches documents.
struct FolmiCommands: Commands {
    let model: FolmiModel
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { model.showSettings = true }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("打开仓库…") { model.openRepository() }.keyboardShortcut("o")
                .disabled(model.busy)
            Button("创建演示仓库") { model.loadDemo() }.disabled(model.busy)
            Button("重新读取状态") { model.refresh() }.keyboardShortcut("r").disabled(!model.hasSnapshot || model.busy)
        }
        CommandGroup(after: .undoRedo) {
            Divider()
            Button(model.undoLabel.map { "撤销 Git：\($0.prefix(40))" } ?? "撤销 Git 操作") { model.undoGitOperation() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(model.undoLabel == nil || model.busy)
            Button(model.redoLabel.map { "重做 Git：\($0.prefix(40))" } ?? "重做 Git 操作") { model.redoGitOperation() }
                .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                .disabled(model.redoLabel == nil || model.busy)
        }
        CommandGroup(after: .saveItem) {
            Button(model.showCommitComposer ? "提交暂存区" : "准备提交…", action: model.handleCommitShortcut)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.hasSnapshot || model.busy)
        }
        CommandMenu("查找") {
            Button("万能搜索…", action: model.openPalette).keyboardShortcut("k")
            Button("问 AI…", action: model.openAsk).keyboardShortcut("l").disabled(!model.hasSnapshot)
            Button("说人话（终端选中内容）") {
                if let text = model.terminalSelection, !text.isEmpty { model.assist(.plain, text: text, source: "终端选中内容") }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift]).disabled(model.terminalSession == nil)
            Button("回放 Claude 的改动", action: { model.showReplay = true }).disabled(!model.hasSnapshot)
            Button("全项目待办", action: { model.showTasks = true }).keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!model.hasSnapshot)
            Button("项目总览", action: { model.showOverview = true }).keyboardShortcut("o", modifiers: [.command, .shift])
            Button("这份文档的演变史", action: { model.showDocHistory = true }).keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(!model.isMarkdownDocument)
            Button("随手记一条…（⌃⌥⌘I）") { InboxPanel.shared.show(model: model) }
            Divider()
            Button("快速打开文件…", action: model.openQuickOpen).keyboardShortcut("p")
                .disabled(!model.hasSnapshot || model.busy)
            Button("项目全文搜索…", action: model.openProjectSearch).keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!model.hasSnapshot || model.busy)
        }
        CommandMenu("面板") {
            ForEach(FolmiPane.allCases, id: \.self) { pane in
                Button("聚焦\(pane.title)") { model.focusPane(pane) }.keyboardShortcut(pane.shortcut)
                    .disabled(!model.hasSnapshot)
            }
            Button("文件树") { model.showSideTab(.files) }.keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.hasSnapshot)
            Button("Git 改动") { model.showSideTab(.changes) }.keyboardShortcut("g", modifiers: [.control, .shift])
                .disabled(!model.hasSnapshot)
            Divider()
            Button(model.paneLayout.maximized == nil ? "最大化当前面板" : "还原面板布局") { model.toggleMaximize() }
                .keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(!model.hasSnapshot)
            Button("收起当前面板") { model.closePane() }.keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(!model.hasSnapshot)
            Divider()
            Button("发送审查评论到终端") { model.sendReviewCommentsToTerminal() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(model.sendableReviewComments.isEmpty)
            Button("发送编辑器选中的行到终端") { model.sendEditorSelectionToTerminal() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!model.hasSnapshot || model.content != .editor || model.editorWorkspace?.selectedDocument == nil)
            Divider()
            Button("新建终端标签") { model.newTerminalTab() }
                .keyboardShortcut("`", modifiers: [.control, .shift])
                .disabled(!model.hasSnapshot)
            Divider()
            Button("快捷键一览（按住 ⌘ 也能看）", action: model.toggleShortcuts).keyboardShortcut("/")
        }
        CommandMenu("编辑显示") {
            Button("Markdown 阅读 / 编辑", action: model.toggleMarkdownPreview)
                .keyboardShortcut("m", modifiers: [.option, .shift])
                .disabled(!model.isMarkdownDocument || model.content != .editor || model.busy)
            Divider()
            ThemeMenuItems(model: model)
            Divider()
            Button("接入 agent…") { model.showHooksSetup = true }.disabled(!model.hasSnapshot)
            Button("记住了什么…") { model.showMemory = true }.disabled(!model.hasSnapshot)
        }
    }
}
