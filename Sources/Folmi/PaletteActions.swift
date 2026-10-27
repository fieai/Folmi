import AppKit
import Foundation
import FolmiCore

/// ⌘K's commands and what picking an item does; the index of Markdown headings and tasks behind it.
extension FolmiModel {
    struct PaletteCommand {
        let id: String
        let title: String
        let keywords: String
        let enabled: Bool
        let run: () -> Void
    }

    var paletteCommands: [PaletteCommand] {
        let open = snapshot != nil
        return [
            PaletteCommand(id: "large-repo", title: largeRepositoryOn ? "关闭大仓库模式" : "打开大仓库模式（读取状态更快）",
                           keywords: "large repo fsmonitor 大仓库 慢 性能 untracked cache", enabled: open) { [weak self] in
                guard let self else { return }
                self.setLargeRepository(!self.largeRepositoryOn)
            },
            PaletteCommand(id: "shortcuts", title: "快捷键一览", keywords: "shortcut keyboard 快捷键 按键 帮助", enabled: true) { [weak self] in self?.toggleShortcuts() },
            PaletteCommand(id: "review", title: "逐个验收改动", keywords: "review 全部改动 验收 看改动", enabled: open) { [weak self] in self?.showContent(.allChanges) },
            PaletteCommand(id: "stage-all", title: "全部暂存", keywords: "stage all add 暂存 全部", enabled: open && !busy && snapshot?.files.contains(where: \.hasWorking) == true) { [weak self] in self?.stageAll() },
            PaletteCommand(id: "unstage-all", title: "全部取消暂存", keywords: "unstage all reset 取消暂存 全部", enabled: open && !busy && snapshot?.files.contains(where: \.hasStaged) == true) { [weak self] in self?.unstageAll() },
            PaletteCommand(id: "commit", title: "提交暂存区", keywords: "commit 提交", enabled: canCommit) { [weak self] in self?.commit() },
            PaletteCommand(id: "message", title: "AI 重新写提交说明", keywords: "commit message 提交说明 生成", enabled: open) { [weak self] in self?.scheduleCommitSuggestion(force: true) },
            PaletteCommand(id: "undo", title: undoLabel.map { "撤销 Git：\($0)" } ?? "撤销 Git 操作", keywords: "undo 撤销 撤回", enabled: undoLabel != nil) { [weak self] in self?.undoGitOperation() },
            PaletteCommand(id: "redo", title: redoLabel.map { "重做 Git：\($0)" } ?? "重做 Git 操作", keywords: "redo 重做", enabled: redoLabel != nil) { [weak self] in self?.redoGitOperation() },
            PaletteCommand(id: "files", title: "显示文件树", keywords: "files tree 文件", enabled: open) { [weak self] in self?.showSideTab(.files) },
            PaletteCommand(id: "changes", title: "显示改动列表", keywords: "changes 改动 git", enabled: open) { [weak self] in self?.showSideTab(.changes) },
            PaletteCommand(id: "history", title: "提交历史", keywords: "history log 历史 提交图", enabled: open) { [weak self] in self?.showContent(.history) },
            PaletteCommand(id: "turn", title: "只看 AI 最近一轮的改动", keywords: "replay claude codex ai 回放 轮次 每一轮 批次 turn", enabled: open && !turnChoices.isEmpty) { [weak self] in self?.showTurn(self?.turnChoices.first?.id) },
            PaletteCommand(id: "tasks", title: "全项目待办", keywords: "tasks todo 待办 任务", enabled: open) { [weak self] in self?.showTasks = true },
            PaletteCommand(id: "terminal", title: "显示 / 隐藏终端", keywords: "terminal 终端 shell", enabled: open) { [weak self] in self?.toggleTerminal() },
            PaletteCommand(id: "newTerminal", title: "新建终端标签", keywords: "terminal new 终端", enabled: open) { [weak self] in self?.newTerminalTab() },
            PaletteCommand(id: "hooks", title: "接入 agent（hooks / MCP）", keywords: "claude codex hooks mcp 接入 活动 撤回 guardrails 评论", enabled: open) { [weak self] in self?.showHooksSetup = true },
            PaletteCommand(id: "worktrees", title: "工作树", keywords: "worktree worktrees codex claude 工作树 文件夹 清理", enabled: open) { [weak self] in self?.showWorktrees = true },
            PaletteCommand(id: "remotes", title: "远端：查看、添加、删除", keywords: "remote remotes origin upstream url 远端 远程 地址", enabled: open) { [weak self] in self?.showRemotes = true },
            PaletteCommand(id: "memory", title: "记住了什么", keywords: "memory rules learning 规则 记忆 提议 claude.md agents.md", enabled: open) { [weak self] in self?.showMemory = true },
            PaletteCommand(id: "aiBatch", title: "撤回 Claude 最近一批改动", keywords: "claude undo batch 撤回 回滚", enabled: aiBatches.last?.canUndo == true) { [weak self] in self?.undoLatestAIBatch() },
            PaletteCommand(id: "refresh", title: "刷新", keywords: "refresh reload 刷新", enabled: open && !busy) { [weak self] in self?.refresh() },
            PaletteCommand(id: "search", title: "项目全文搜索", keywords: "search grep 搜索 全文", enabled: open) { [weak self] in self?.openProjectSearch() },
            PaletteCommand(id: "deliver", title: "推送到远端…", keywords: "push deliver 推送 交付", enabled: open && !busy) { [weak self] in self?.prepareDelivery() },
            PaletteCommand(id: "stash", title: "暂放全部改动", keywords: "stash 暂放 收起 搁置 暂存", enabled: open && !busy && snapshot?.files.isEmpty == false) { [weak self] in self?.stashAllChanges() },
            PaletteCommand(id: "stashes", title: "暂放的改动…", keywords: "stash list pop 暂放 拿回 收起 放回 恢复", enabled: open) { [weak self] in self?.openStashes() },
            PaletteCommand(id: "pull", title: "从远端拉取…", keywords: "pull fetch 拉取 取回 更新", enabled: open && !busy) { [weak self] in self?.preparePull() },
            PaletteCommand(id: "reading", title: "Markdown 阅读 / 编辑", keywords: "markdown read edit 阅读 编辑", enabled: isMarkdownDocument) { [weak self] in self?.toggleMarkdownPreview() },
            PaletteCommand(id: "ai", title: "AI 设置", keywords: "ai settings model key 模型 设置", enabled: true) { [weak self] in self?.showAISettings = true },
            PaletteCommand(id: "quickCheck", title: "AI 快检当前改动", keywords: "review check 快检 风险 解释", enabled: fileDiff != nil) { [weak self] in self?.quickCheckDiff() },
            PaletteCommand(id: "split", title: "AI 建议怎么拆分提交", keywords: "split commit 拆分", enabled: snapshot?.files.contains(where: \.hasStaged) == true) { [weak self] in self?.suggestSplit() },
            PaletteCommand(id: "neat", title: "整理文档（/neat-freak 发到终端）", keywords: "neat freak 整理 文档 收尾", enabled: open) { [weak self] in self?.sendSlashCommand("/neat-freak") },
            PaletteCommand(id: "handoff", title: "写交接（/handoff 发到终端）", keywords: "handoff 交接", enabled: open) { [weak self] in self?.sendSlashCommand("/handoff") },
            PaletteCommand(id: "ask", title: "问 AI（当前文件或改动）", keywords: "ai ask chat 问 对话", enabled: open) { [weak self] in self?.openAsk() },
            PaletteCommand(id: "open", title: "打开仓库…", keywords: "open repository 仓库 项目", enabled: !busy) { [weak self] in self?.openRepository() },
            PaletteCommand(id: "lineBlame", title: editorLineBlame ? "不在光标所在行显示最后修改人" : "在光标所在行显示最后修改人",
                           keywords: "blame author 作者 谁改的 修改人 最后修改 行", enabled: true) { [weak self] in self?.editorLineBlame.toggle() },
            PaletteCommand(id: "dark", title: "切换明暗", keywords: "theme dark light 明暗 主题", enabled: true) { [weak self] in
                guard let self else { return }
                self.appearance = self.appearance == .dark ? .light : .dark
            },
        ]
    }

    func openPalette() {
        guard !showQuickOpen, !showProjectSearch, !showDelivery, !showPull else { return }
        paletteItemsCache = makePaletteItems()
        showPalette = true
    }

    private func makePaletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        for command in paletteCommands where command.enabled {
            items.append(PaletteItem(id: "command:" + command.id, kind: .command, title: command.title, subtitle: "", action: .command(command.id),
                                     keywords: command.keywords))
        }
        guard snapshot != nil else { return items }
        for file in snapshot?.files ?? [] {
            items.append(PaletteItem(id: "change:" + file.path, kind: .change, title: (file.path as NSString).lastPathComponent,
                                     subtitle: file.path, action: .showChange(file.path)))
        }
        items += paletteStaticItems
        var commits = Set<String>()
        for commit in snapshot?.commits ?? [] where commits.insert(commit.id).inserted {
            items.append(PaletteItem(id: "commit:" + commit.id, kind: .commit, title: commit.subject, subtitle: commit.shortID, action: .showCommit(commit.id),
                                     keywords: commit.shortID))
        }
        for node in history where commits.insert(node.id).inserted {
            items.append(PaletteItem(id: "commit:" + node.id, kind: .commit, title: node.subject, subtitle: node.shortID, action: .showCommit(node.id),
                                     keywords: node.shortID))
        }
        return items
    }

    func pickPaletteItem(_ item: PaletteItem) {
        paletteUsage.note(item.id)
        paletteUsage.save()
        // The sheet is still closing; act once it is gone so focus lands in the destination.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch item.action {
            case .command(let id): self.paletteCommands.first { $0.id == id && $0.enabled }?.run()
            case .openFile(let path): self.editPath(path); self.focusPane(.editor)
            case .openLine(let path, let line):
                guard let editor = self.editorWorkspace else { return }
                do {
                    try editor.reveal(path: path, line: line + 1, column: 1)
                    self.content = .editor
                    self.focusPane(.editor)
                } catch { self.report(error, title: "打开文件失败") }
            case .showChange(let path):
                guard let change = self.snapshot?.files.first(where: { $0.path == path }) else { return }
                if self.area == .working && !change.hasWorking { self.setArea(.staged) }
                if self.area == .staged && !change.hasStaged { self.setArea(.working) }
                self.selectFiles([change.id])
            case .showCommit(let id):
                self.showContent(.history)
                Task { await self.selectCommit(id) }
            case .askAgent(let text):
                self.askAgent(text)
            }
        }
    }

    /// Files, headings and open tasks, prepared in the background (folding 30 000 names takes a while).
    func schedulePaletteItems() {
        paletteStaticTask?.cancel()
        let paths = browserPaths, entries = markdownIndex?.entries ?? [], root = repositoryURL
        paletteStaticTask = Task { [weak self] in
            let items = await Task.detached(priority: .utility) { Self.staticPaletteItems(paths: paths, entries: entries) }.value
            guard let self, !Task.isCancelled, self.repositoryURL == root else { return }
            self.paletteStaticItems = items
        }
    }
    nonisolated static func staticPaletteItems(paths: [String], entries: [MarkdownIndex.Entry]) -> [PaletteItem] {
        var items: [PaletteItem] = []
        items.reserveCapacity(min(paths.count, 30_000) + entries.count)
        for path in paths.prefix(30_000) {
            items.append(PaletteItem(id: "file:" + path, kind: .file, title: (path as NSString).lastPathComponent, subtitle: path, action: .openFile(path)))
        }
        for entry in entries {
            switch entry.kind {
            case .heading(let level):
                items.append(PaletteItem(id: "line:" + entry.id, kind: .heading, title: entry.text,
                                         subtitle: "\(entry.path) · H\(level)", action: .openLine(entry.path, entry.line)))
            case .task(let done) where !done:
                items.append(PaletteItem(id: "line:" + entry.id, kind: .task, title: entry.text, subtitle: entry.path, action: .openLine(entry.path, entry.line)))
            default: break
            }
        }
        return items
    }

    // MARK: Markdown index

    /// Re-reads changed Markdown files a moment after the tree or status changed.
    func scheduleMarkdownIndex() {
        guard let root = repositoryURL else { return }
        markdownIndexTask?.cancel()
        let paths = browserPaths, previous = markdownIndex?.files.isEmpty == false && markdownIndexRoot == root ? markdownIndex : nil
        markdownIndexTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            let index = await Task.detached(priority: .utility) { MarkdownIndex.build(root: root, paths: paths, previous: previous) }.value
            guard let self, !Task.isCancelled, self.repositoryURL == root else { return }
            if index.revision != self.markdownIndex?.revision || self.markdownIndexRoot != root {
                self.markdownIndex = index; self.markdownIndexRoot = root
                self.schedulePaletteItems()
            }
        }
    }
}

extension FolmiModel {
    /// One letter per changed file for the tree: what the work tree (else the index) did to it.
    var changeCodes: [String: String] {
        Dictionary((snapshot?.files ?? []).map { file -> (String, String) in
            if file.isUntracked { return (file.path, "A") }
            let code = [".", " "].contains(file.worktreeCode) ? file.indexCode : file.worktreeCode
            return (file.path, ["A", "D", "M"].contains(code) ? code : "M")
        }, uniquingKeysWith: { first, _ in first })
    }
    var taskCounts: [String: TaskCount] {
        guard let files = markdownIndex?.files else { return [:] }
        var result: [String: TaskCount] = [:]
        for (path, info) in files { let tasks = info.tasks; if tasks.total > 0 { result[path] = TaskCount(done: tasks.done, total: tasks.total) } }
        return result
    }
}
