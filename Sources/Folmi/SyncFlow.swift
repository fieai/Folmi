import SwiftUI
import FolmiCore

/// Where a pull that stopped on a conflict started: one ⌘Z after it finishes goes back here, on this branch.
struct PullStart {
    let head: String
    let branch: String?
}

/// Fetching and pulling. Fetches run in the background (on open and every few minutes), never prompt and never
/// touch files; a pull is previewed first, fast-forward by default, and ⌘Z goes back to before it.
extension FolmiModel {
    static let fetchInterval: Duration = .seconds(120)

    /// Fetches once now and then every `fetchInterval` while this project stays open. Quiet: a failure is kept for
    /// the pull sheet, never shown as an alert.
    func startBackgroundFetch() {
        fetchTask?.cancel()
        lastFetch = nil; fetchProblem = nil
        guard autoRefresh, let root = repositoryURL else { return }
        fetchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchNow(root: root)
                try? await Task.sleep(for: Self.fetchInterval)
            }
        }
    }

    /// One fetch for `root`; skipped without a remote or while another fetch runs. The status refresh that follows
    /// updates ↑ / ↓.
    func fetchNow(root: URL) async {
        guard !fetching, repositoryURL == root, snapshot?.remotes.isEmpty == false else { return }
        fetching = true
        defer { fetching = false }
        let environment = commandEnvironment
        let result = await Task.detached(priority: .utility) { () -> String? in
            do { _ = try GitRepository.fetch(root: root, environment: environment); return nil }
            catch { return error.localizedDescription }
        }.value
        guard repositoryURL == root else { return }
        lastFetch = Date(); fetchProblem = result
        refreshInBackground()
        // Other projects' ahead / behind come from their tracking branches too: re-read them for the menu bar.
        if !gitStartupState.blocksGit { board.refresh(projects: projects) }
        if result == nil { await checkReviewWatches(root: root) }
    }

    /// A sheet by name, for `--present` screenshots.
    func present(_ sheet: String) {
        switch sheet {
        case "pull": preparePull()
        case "formulas":
            editPath("docs/formulas.md")
            if editorWorkspace?.markdownReading == false { toggleMarkdownPreview() }
        case "stash":
            stashAllChanges()
            Task { while busy { try? await Task.sleep(for: .milliseconds(50)) }; openStashes() }
        default: break
        }
    }

    /// Opens the pull sheet: fetches first so the plan shows what the remote has right now.
    func preparePull() {
        guard !busy, let repository, let root = repositoryURL, snapshot != nil else { return }
        pullPlan = nil; pullProblem = nil; pullLoading = true
        showPull = true
        Task {
            await fetchNow(root: root)
            do {
                let plan = try await repository.pullPlan()
                guard repositoryURL == root else { return }
                pullPlan = plan
                pullKind = plan.ahead > 0 ? .rebase : .fastForward
            } catch { pullProblem = error.localizedDescription }
            pullLoading = false
        }
    }

    var pullBlockedReason: String? { pullPlan?.blocked(pullKind) }
    var canPull: Bool { !busy && !pullLoading && pullPlan != nil && pullBlockedReason == nil }

    func runPull() {
        guard canPull, let repository, let plan = pullPlan else { return }
        let kind = pullKind, key = repositoryURL?.path ?? ""
        let title = "拉取 \(plan.upstream)"
        mutate(title) { [weak self] in
            let branch = try await repository.currentBranchRef()
            let outcome = try await repository.pull(kind, plan: plan)
            return await MainActor.run {
                guard let self else { return "" }
                self.showPull = false; self.pullPlan = nil
                switch outcome {
                case let .done(before, after):
                    self.pushUndo(title, .reset(restore: before, current: after, branch: branch))
                    let how = kind == .fastForward ? "快进" : (kind == .rebase ? "变基" : "合并")
                    return "已\(how)到 \(plan.upstream)：取回 \(plan.behind) 个提交（\(before.prefix(7)) → \(after.prefix(7))）。⌥⌘Z 可回到拉取前。"
                case let .conflict(operation, files):
                    self.pullStartHeads[key] = PullStart(head: plan.head, branch: branch)
                    self.showSideTab(.changes)
                    self.errorMessage = Self.conflictHelp(operation, files: files)
                    return "\(operation.title)时有冲突，停在中途：\n" + files.joined(separator: "\n")
                }
            }
        }
    }

    static func conflictHelp(_ operation: RepositoryOperation, files: [String]) -> String {
        let list = files.prefix(6).joined(separator: "\n") + (files.count > 6 ? "\n…" : "")
        let next = operation == .rebase
            ? "在编辑器里解决冲突、暂存这些文件，然后点改动列表上方的「继续变基」。"
            : "在编辑器里解决冲突、暂存这些文件，然后照常提交，就完成了合并。"
        return "\(operation.title)时这些文件有冲突：\n\(list)\n\n\(next)\n不想继续的话，点「放弃\(operation.title)」，分支和文件会回到拉取前。"
    }

    /// Goes on with a rebase whose conflicts are resolved and staged.
    func continueRebase() {
        guard let repository, let state = snapshot else { return }
        let key = state.root.path
        mutate("继续变基") { [weak self] in
            let outcome = try await repository.continueRebase(expectedFingerprint: state.fingerprint)
            return await MainActor.run {
                guard let self else { return "" }
                if case let .conflict(_, files)? = outcome {
                    self.errorMessage = Self.conflictHelp(.rebase, files: files)
                    return "下一个提交又有冲突：\n" + files.joined(separator: "\n")
                }
                return "变基完成。"
            }
        } after: { [weak self] in
            // Finished: the whole pull is one ⌘Z, back to the commit before it started.
            guard let self, self.snapshot?.operation == nil, let start = self.pullStartHeads.removeValue(forKey: key),
                  let head = self.snapshot?.head else { return }
            let delivering = self.deliveryAfterRebase.remove(key) != nil
            self.pushUndo(delivering ? "变基" : "拉取（变基）", .reset(restore: start.head, current: head, branch: start.branch))
            // A delivery stopped on this rebase: back to the sheet, previewed against the rebased commit.
            // (Next turn: the model is still busy with this step until it returns.)
            if delivering { Task { @MainActor in self.prepareDelivery(); self.preflightDelivery() } }
        }
    }

    /// Gives up the rebase or merge in progress; branch and files go back to just before it.
    func abortOperation() {
        guard let repository, let operation = snapshot?.operation else { return }
        let key = repositoryURL?.path ?? ""
        mutate("放弃\(operation.title)") { [weak self] in
            let done = try await repository.abortOperation()
            await MainActor.run { _ = self?.pullStartHeads.removeValue(forKey: key); _ = self?.deliveryAfterRebase.remove(key) }
            return "已放弃\(done.title)，分支和文件回到了开始之前。"
        }
    }
}

/// The pull preview: what the remote has, which way to bring it in, and the exact command, before anything runs.
struct PullSheet: View {
    @Bindable var model: FolmiModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = PerfLog.body("PullSheet")
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("从远端拉取").themedFont(.title3.weight(.semibold), points: 15)
                    Text("把远端分支上的新提交取到本地。先看要执行的命令，确认后再拉取；拉取后 ⌥⌘Z 可以回到拉取前。")
                        .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.pullLoading || model.busy { ProgressView().controlSize(.small) }
            }

            if let plan = model.pullPlan {
                summary(plan)
                if plan.ahead > 0 && !plan.upToDate {
                    VStack(alignment: .leading, spacing: 6) {
                        ThemedSegmented(options: [(GitRepository.PullKind.rebase, "变基到远端之上"), (.merge, "合并")],
                                        selection: $model.pullKind, fillsWidth: true)
                        Text(model.pullKind == .rebase
                             ? "把你的 \(plan.ahead) 个本地提交挪到远端最新提交之后，历史保持一条线。"
                             : "保留两边的历史，新建一个合并提交把远端的改动并进来。")
                            .themedFont(.caption, points: 10).foregroundStyle(.secondary)
                    }
                    .disabled(model.busy)
                }
                if !plan.upToDate {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("将要执行的命令", systemImage: "terminal").themedFont(.caption.weight(.medium), points: 10)
                        Text(plan.command(model.pullKind))
                            .themedFont(.system(size: 12, design: .monospaced), points: 12)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(model.pullKind == .fastForward
                             ? "只快进：本地没有远端缺少的提交时才会执行，不会产生合并提交。没提交的改动会保留；和远端改到同一些文件时会拒绝，什么都不改。"
                             : "遇到冲突会停在中途：解决冲突后继续，或者放弃，回到拉取前的样子。")
                            .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themedBackground(ThemeColor(token: .hover), .control)
                }
                if let reason = model.pullBlockedReason, !plan.upToDate {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .themedFont(.caption, points: 10).foregroundStyle(ThemeColor(token: .modified))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let problem = model.pullProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .themedFont(.caption, points: 10).foregroundStyle(ThemeColor(token: .modified))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("正在从远端取回…").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            }

            if let problem = model.fetchProblem {
                Text("取回远端失败，下面显示的是上次取回的结果：\(problem)")
                    .themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(3)
            } else if let date = model.lastFetch {
                Text("刚才从远端取回过（\(date.formatted(date: .omitted, time: .shortened))）。打开项目后每 2 分钟会自动取回一次，不会改你的文件。")
                    .themedFont(.caption, points: 10).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("重新取回", action: model.preparePull).disabled(model.busy || model.pullLoading)
                    .help("再从远端取回一次，更新上面的数字")
                Button(model.pullPlan?.upToDate == true ? "已是最新" : "拉取", action: model.runPull)
                    .buttonStyle(.folmiProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPull)
                    .help(model.pullBlockedReason ?? "执行上面列出的命令")
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func summary(_ plan: GitRepository.PullPlan) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            Text("\(plan.branch)  ←  \(plan.upstream)").themedFont(.system(size: 13, weight: .medium, design: .monospaced), points: 13)
            Spacer()
            if plan.upToDate {
                Text("已经是最新的").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            } else {
                Text("↓\(plan.behind) 远端新提交").themedFont(.caption, points: 10).monospacedDigit()
            }
            if plan.ahead > 0 {
                Text("↑\(plan.ahead) 本地未推送").themedFont(.caption, points: 10).monospacedDigit().foregroundStyle(ThemeColor(token: .modified))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .themedBackground(ThemeColor(token: .hover, opacity: 0.6), .control)
    }
}

/// Shown above the change list while a rebase or merge waits half way: what to do next, and the way out.
struct OperationNotice: View {
    let model: FolmiModel
    let operation: RepositoryOperation

    var body: some View {
        let conflicts = model.snapshot?.files.filter(\.isConflict).count ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(ThemeColor(token: .modified))
                Text("\(operation.title)停在中途").themedFont(.system(size: 12.5, weight: .semibold), points: 12.5)
            }
            Text(conflicts > 0
                 ? "还有 \(conflicts) 个冲突文件：解决后暂存，再\(operation == .rebase ? "继续变基" : "提交完成合并")。"
                 : (operation == .rebase ? "冲突都解决了，可以继续变基。" : "冲突都解决了，写好提交说明提交即可完成合并。"))
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if operation == .rebase {
                    Button("继续变基", action: model.continueRebase)
                        .buttonStyle(.folmiProminent).controlSize(.small)
                        .disabled(model.busy || conflicts > 0)
                }
                Button("放弃\(operation.title)", action: model.abortOperation)
                    .controlSize(.small).disabled(model.busy)
                    .help("分支和文件回到\(operation.title)开始之前")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedBackground(ThemeColor(token: .modified, opacity: 0.08), .control)
        .overlay(RoundedRectangle(cornerRadius: model.theme.style.radius(.control), style: .continuous)
            .strokeBorder(ThemeColor(token: .modified, opacity: 0.35)))
    }
}
