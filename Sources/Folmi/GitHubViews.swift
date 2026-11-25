import AppKit
import SwiftUI

struct GitHubDeliveryDetails: View {
    @Bindable var model: FolmiModel
    let target: GitHubTarget

    var body: some View {
        let status = model.githubDeliveryStatus
        let loading = model.githubRequests[target] != nil
        VStack(alignment: .leading, spacing: 6) {
            if let pr = status?.pullRequest {
                Text("\(pr.title) · \(pr.statusTitle)")
            }
            if let link = model.visibleGitHubDraft?.created ?? status?.pullRequest.map({ GitHubPRLink(number: $0.number, url: $0.url) }) {
                Link("在浏览器打开 PR #\(link.number)", destination: link.url)
            }
            if let problem = status?.problem {
                Text(problem).textSelection(.enabled)
            }
            if let status, case let .unavailable(reason, command) = status.access {
                Text(reason)
                HStack {
                    Text(command).fontDesign(.monospaced).textSelection(.enabled)
                    Button("复制命令") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
            }
            if loading {
                WaitingIndicator("正在读取 PR 状态…").controlSize(.small)
            } else if let status, case .otherRemote = status.access, status.problem == nil {
                EmptyView()
            } else {
                Button("刷新 PR 状态") { Task { await model.refreshGitHubForDelivery() } }
                    .disabled(model.busy)
            }
        }
        .themedFont(.caption, points: 10)
        .foregroundStyle(.secondary)
    }
}

struct GitHubDraftView: View {
    @Binding var draft: GitHubDraft
    let busy: Bool
    let canSubmit: Bool
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分支已推送，可以创建 PR").themedFont(.headline, points: 13)
            TextField("PR 标题", text: $draft.title).themedTextField()
                .accessibilityLabel("PR 标题")
            HStack {
                Text("目标分支")
                TextField("目标分支", text: $draft.base).themedTextField()
                    .accessibilityLabel("目标分支")
                Toggle("草稿", isOn: $draft.isDraft)
            }
            Text("PR 描述")
            TextEditor(text: $draft.body)
                .themedFont(.body, points: 12)
                .frame(height: 82).padding(4).themedEditorFrame()
                .accessibilityLabel("PR 描述")
            if let problem = draft.prefillProblem {
                Text(problem).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let problem = draft.createProblem {
                ScrollView {
                    Text("创建 PR 失败。分支已经推送，可以重试。\n\(problem)")
                        .foregroundStyle(ThemeColor(token: .modified)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 65)
            }
            if let problem = draft.baseProblem {
                Text(problem).foregroundStyle(.secondary)
            }
            BusyButton(busy ? "正在创建…" : "创建 PR", busy: busy, action: create)
                .buttonStyle(.folmiProminent)
                .disabled(busy || !canSubmit)
        }
        .disabled(busy)
        .themedFont(.caption, points: 11)
        .padding(12)
        .themedBackground(ThemeColor(token: .hover), .control)
    }
}

struct GitHubStatusBadge: View {
    let model: FolmiModel
    let target: GitHubTarget
    @State private var presented = false

    var body: some View {
        if let status = model.githubStatuses[target], let pr = status.pullRequest {
            HStack(spacing: 5) {
                Button {
                    presented = true
                    Task { await model.refreshGitHub(target) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pr.capsuleTitle(comments: status.comments))
                        if let date = status.checkedAt {
                            TimelineView(.everyMinute) { context in
                                Text(Self.ageTitle(date, now: context.date)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("打开 PR 评审意见和检查")
                .popover(isPresented: $presented, arrowEdge: .trailing) {
                    GitHubReviewPopover(model: model, target: target, presented: $presented)
                }
                refreshButton
            }
            .themedFont(.caption, points: 10)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .themedCapsule(ThemeColor(token: .accent, opacity: 0.12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var refreshButton: some View {
        PaneIconButton(symbol: "arrow.clockwise", help: "刷新 PR 状态") { Task { await model.refreshGitHub(target) } }
            .disabled(model.githubRequests[target] != nil)
    }

    nonisolated static func ageTitle(_ date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes == 0 { return "刚刚更新" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        if minutes < 1_440 { return "\(minutes / 60) 小时前" }
        return "\(minutes / 1_440) 天前"
    }
}

private struct GitHubReviewPopover: View {
    let model: FolmiModel
    let target: GitHubTarget
    @Binding var presented: Bool
    @State private var selected: Set<String> = []
    @State private var loadingLog = false
    @State private var logProblem: String?

    var body: some View {
        let status = model.githubStatuses[target]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let pr = status?.pullRequest {
                    Link("PR #\(pr.number) · \(pr.title)", destination: pr.url)
                        .themedFont(.headline, points: 13)
                } else {
                    Text("当前分支没有打开的 PR").themedFont(.headline, points: 13)
                }
                Spacer()
                if model.githubRequests[target] != nil {
                    WaitingIndicator().controlSize(.small).accessibilityLabel("正在刷新 PR")
                } else {
                    PaneIconButton(symbol: "arrow.clockwise", help: "刷新 PR 状态") { Task { await model.refreshGitHub(target) } }
                }
            }
            if let status, case let .unavailable(reason, _) = status.access { Text(reason).foregroundStyle(.secondary) }
            if let problem = status?.problem { Text(problem).foregroundStyle(.secondary).textSelection(.enabled) }
            if let status, let pr = status.pullRequest {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        reviewComments(status.comments, pr: pr)
                        Divider()
                        failedChecks(pr, access: status.access)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 410)
            }
        }
        .themedFont(.body, points: 12)
        .padding(16).frame(width: 480)
    }

    @ViewBuilder private func reviewComments(_ comments: [GitHubComment]?, pr: GitHubPullRequest) -> some View {
        HStack {
            Text("没解决的评审意见").fontWeight(.semibold)
            Spacer()
            let picked = (comments ?? []).filter { selected.contains($0.id) }
            Button("加到 AI 输入框（\(picked.count)）") { attach(picked) }
                .disabled(picked.isEmpty || !model.canAttachGitHubContext)
        }
        if let comments {
            if comments.isEmpty { Text("没有没解决的评审意见").foregroundStyle(.secondary) }
            let groups = Dictionary(grouping: comments, by: \.path)
            ForEach(groups.keys.sorted(), id: \.self) { path in
                VStack(alignment: .leading, spacing: 8) {
                    Text(path).fontWeight(.medium).textSelection(.enabled)
                    ForEach(groups[path] ?? []) { comment in
                        reviewComment(comment, pullRequestHead: pr.headRefOid)
                    }
                }
            }
        } else if model.githubRequests[target] == nil {
            Text("评审意见暂不可用").foregroundStyle(.secondary)
        }
    }

    private func reviewComment(_ comment: GitHubComment, pullRequestHead: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: Binding(get: { selected.contains(comment.id) }, set: {
                if $0 { selected.insert(comment.id) } else { selected.remove(comment.id) }
            })) {
                Text(comment.jumpLine.map { "\(comment.author) · 第 \($0) 行" } ?? comment.author)
            }
            Text(comment.body).textSelection(.enabled)
            if comment.locationMayHaveChanged(localHead: model.snapshot?.head, pullRequestHead: pullRequestHead) {
                Text("本地代码可能已经变了").foregroundStyle(.secondary)
            }
            HStack {
                Button("跳到位置") {
                    presented = false
                    model.revealLinked(path: comment.path, line: comment.jumpLine, openInEditor: true)
                }.disabled(model.busy)
                Button("加到 AI 输入框") { attach([comment]) }
                    .disabled(!model.canAttachGitHubContext)
            }
            .controlSize(.small)
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .themedBackground(ThemeColor(token: .hover), .control)
    }

    @ViewBuilder private func failedChecks(_ pr: GitHubPullRequest, access: GitHubAccess) -> some View {
        Text("失败的检查").fontWeight(.semibold)
        if pr.failedChecks.isEmpty { Text("没有失败的检查").foregroundStyle(.secondary) }
        ForEach(Array(pr.failedChecks.enumerated()), id: \.offset) { _, check in
            HStack {
                if let url = check.url { Link(check.title, destination: url) }
                else { Text(check.title) }
                Spacer()
                if case let .ready(cli) = access, GitHubActionsRun(check: check, on: cli.repository.host) != nil {
                    Button("加到 AI 输入框") { attachLog(check) }
                        .disabled(loadingLog || !model.canAttachGitHubContext)
                }
            }
        }
        if loadingLog { WaitingIndicator("正在读取失败日志…").controlSize(.small) }
        if let logProblem { Text(logProblem).foregroundStyle(.secondary).textSelection(.enabled) }
    }

    private func attach(_ comments: [GitHubComment]) {
        presented = false
        model.attachGitHubComments(comments, for: target)
    }

    private func attachLog(_ check: GitHubCheck) {
        loadingLog = true; logProblem = nil
        Task {
            defer { loadingLog = false }
            do {
                let context = try await model.githubFailedLog(check, for: target)
                guard presented, model.githubBranchTarget == target, model.canAttachGitHubContext else { return }
                presented = false
                model.attachToAgent([context])
            } catch {
                logProblem = "读取失败日志失败。\n\(error.localizedDescription)"
            }
        }
    }
}
