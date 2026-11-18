import Foundation

struct GitHubTarget: Hashable {
    let root: URL
    let remote: String
    let branch: String
}

struct GitHubStatus {
    var access: GitHubAccess
    var endpoint: String?
    var defaultBranch: String?
    var pullRequest: GitHubPullRequest?
    var comments: [GitHubComment]?
    var checkedAt: Date?
    var problem: String?

    var pushTitle: String {
        pullRequest.map { "推送（更新 PR #\($0.number)）" } ?? "推送"
    }

    func canCreate(branch: String) -> Bool {
        guard case .ready = access, let defaultBranch, checkedAt != nil, pullRequest == nil, problem == nil else { return false }
        return branch != defaultBranch
    }
}

struct GitHubDraft {
    let id = UUID()
    let target: GitHubTarget
    let endpoint: String
    let cli: GitHubCLI
    var base: String
    var title: String
    var body = ""
    var isDraft = false
    var prefillProblem: String?
    var createProblem: String?
    var created: GitHubPRLink?

    var baseProblem: String? {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if base == target.branch { return "目标分支需要和已推送的分支不同。" }
        if !FolmiModel.isValidDeliveryBranch(base) { return "填写有效的目标分支名称。" }
        return nil
    }
    var canSubmit: Bool { created == nil && baseProblem == nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func description(subjects: [String], files: Int) -> String {
        let list = subjects.map { "- \($0)" }.joined(separator: "\n")
        return (list.isEmpty ? "" : "## 新提交\n\n\(list)\n\n") + "改动文件数：\(files)"
    }

    static func titlePrompt(subjects: [String], paths: [String]) -> (system: String, user: String)? {
        let subjectsText = subjects.joined(separator: "\n")
        guard !paths.contains(where: SecretScan.isSensitivePath), SecretScan.findings(in: subjectsText).isEmpty else { return nil }
        let chinese = subjectsText.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let prompt = AIPrompts.commitMessage(chinese: chinese, conventional: AIPrompts.usesConventionalCommits(subjects))
            + "\nSummarize the commits for a pull request. Return only the one-line title."
        return (prompt, subjectsText)
    }

    mutating func applySuggestedTitle(_ response: String, replacing placeholder: String) {
        guard title == placeholder, created == nil,
              let subject = FolmiModel.cleanCommitMessage(response).split(whereSeparator: \.isNewline).first else { return }
        title = String(subject)
    }
}

extension FolmiModel {
    var githubBranchTarget: GitHubTarget? {
        guard let snapshot, let root = repositoryURL, snapshot.root == root,
              snapshot.head != nil, !["", "HEAD", "(detached)"].contains(snapshot.branch) else { return nil }
        let remote = upstreamTarget?.remote ?? "origin"
        guard snapshot.remotes.contains(remote) else { return nil }
        return GitHubTarget(root: root, remote: remote, branch: upstreamTarget?.branch ?? snapshot.branch)
    }

    var githubDeliveryTarget: GitHubTarget? {
        guard deliveryKind == .push, let root = repositoryURL, let snapshot, snapshot.root == root,
              !["", "HEAD", "(detached)"].contains(snapshot.branch), (try? makeDelivery()) != nil else { return nil }
        return GitHubTarget(root: root, remote: deliveryRemote, branch: deliveryBranch.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var githubDeliveryStatus: GitHubStatus? { githubDeliveryTarget.flatMap { githubStatuses[$0] } }

    var visibleGitHubDraft: GitHubDraft? {
        guard let githubDraft, githubDraft.target == githubDeliveryTarget else { return nil }
        return githubDraft
    }

    var canSubmitGitHubDraft: Bool {
        guard case .ready = githubDeliveryStatus?.access else { return false }
        return visibleGitHubDraft?.canSubmit == true
    }

    func showGitHubStatusOnFirstChangesDisplay() async {
        guard !isDemo, let root = repositoryURL, githubOpenedProjects.insert(root).inserted,
              let target = githubBranchTarget, githubStatuses[target] == nil else { return }
        await refreshGitHub(target)
    }

    func refreshGitHubForDelivery() async {
        guard let target = githubDeliveryTarget, !isDemo else { return }
        await refreshGitHub(target)
    }

    // Called only from user-facing actions. Snapshot updates and the fetch loop read the cache.
    func refreshGitHub(_ target: GitHubTarget, afterMutation: Bool = false, prNumber: Int? = nil) async {
        guard !isDemo, target.root == repositoryURL, afterMutation || githubRequests[target] == nil else { return }
        let request = UUID()
        githubRequests[target] = request
        var status = githubStatuses[target] ?? GitHubStatus(access: .otherRemote)
        status.problem = nil
        defer {
            if githubRequests[target] == request {
                githubRequests[target] = nil
                githubStatuses[target] = status
                if let pr = status.pullRequest, githubDraft?.target == target, githubDraft?.created == nil {
                    githubDraft?.created = GitHubPRLink(number: pr.number, url: pr.url)
                }
            }
        }
        do {
            let endpoint = try await resolveEndpoint(root: target.root, remote: target.remote)
            let access = try await GitHubCLI.access(remote: endpoint, at: target.root, locate: locateGitHubCLI)
            if status.endpoint != endpoint { status = GitHubStatus(access: access, endpoint: endpoint) }
            status.access = access
            guard case let .ready(cli) = access else { return }

            do {
                status.pullRequest = try await cli.openPullRequest(branch: target.branch, number: prNumber)
                status.checkedAt = Date()
                status.comments = nil
                if let pr = status.pullRequest {
                    do { status.comments = try await cli.unresolvedComments(number: pr.number) }
                    catch { status.problem = "读取评审意见失败。\n\(error.localizedDescription)" }
                }
            } catch {
                status.problem = "读取 PR 失败。\n\(error.localizedDescription)"
            }
            do { status.defaultBranch = try await cli.defaultBranch() }
            catch {
                status.problem = [status.problem, "读取默认分支失败。\n\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
            }
        } catch {
            status.problem = "读取 GitHub 状态失败。\n\(error.localizedDescription)"
        }
    }

    func prepareGitHubDraft(target: GitHubTarget, endpoint: String, head: String, from status: GitHubStatus) async {
        guard case let .ready(cli) = status.access, let base = status.defaultBranch,
              status.endpoint == endpoint, base != target.branch, githubStatuses[target]?.pullRequest == nil else { return }
        var draft = GitHubDraft(target: target, endpoint: endpoint, cli: cli, base: base, title: target.branch)
        var subjects: [String] = []
        var paths: [String] = []
        do {
            // Use the destination's default branch, even if this remote fetches from a different repository.
            let baseHead = try await cli.branchCommit(base)
            let range = "\(baseHead)...\(head)"
            let environment = commandEnvironment
            if (try? await CommandRunner.git(["cat-file", "-e", "\(baseHead)^{commit}"], at: target.root, environment: environment)) == nil {
                _ = await fetchTarget(root: target.root, remote: target.remote, branch: base)
            }
            let output = try await CommandRunner.git(["log", "--format=%s", "\(baseHead)..\(head)", "--"], at: target.root, environment: environment)
            subjects = output.split(whereSeparator: \.isNewline).map(String.init)
            let names = try await CommandRunner.git(["diff", "--name-only", "-z", "--no-ext-diff", range, "--"], at: target.root, environment: environment)
            paths = names.split(separator: "\0").map(String.init)
            draft.title = subjects.count == 1 ? (subjects.first ?? target.branch) : target.branch
            draft.body = GitHubDraft.description(subjects: subjects, files: paths.count)
        } catch {
            draft.prefillProblem = "未能读取提交和改动文件。可以手动填写。\n\(error.localizedDescription)"
        }
        guard githubDeliveryTarget == target else { return }
        githubDraft = draft
        if subjects.count > 1 { suggestGitHubTitle(for: draft, subjects: subjects, paths: paths) }
    }

    private func suggestGitHubTitle(for draft: GitHubDraft, subjects: [String], paths: [String]) {
        let client = AIClient.client(for: .commitMessage, project: draft.target.root.path, settings: aiSettings)
        guard client.isAvailable, let prompt = GitHubDraft.titlePrompt(subjects: subjects, paths: paths) else { return }
        Task {
            guard let response = try? await client.complete(system: prompt.system, user: prompt.user, maxTokens: 120),
                  githubDraft?.id == draft.id, !busy else { return }
            githubDraft?.applySuggestedTitle(response, replacing: draft.title)
        }
    }

    func createGitHubPullRequest() async {
        guard !busy, canSubmitGitHubDraft, let draft = visibleGitHubDraft else { return }
        busy = true
        githubDraft?.createProblem = nil
        defer { busy = false }
        do {
            let base = draft.base.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await CommandRunner.git(["check-ref-format", "refs/heads/\(base)"], at: draft.target.root, environment: commandEnvironment)
            let endpoint = try await resolveEndpoint(root: draft.target.root, remote: draft.target.remote)
            guard endpoint == draft.endpoint else { throw FolmiFailure(message: "远程推送地址已变化。请检查地址后重新推送。") }
            let link = try await draft.cli.createPullRequest(branch: draft.target.branch, base: base,
                                                             title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                             body: draft.body, draft: draft.isDraft)
            record("已创建 GitHub PR #\(link.number)", link.url.absoluteString)
            await refreshGitHub(draft.target, afterMutation: true, prNumber: link.number)
            githubDraft?.created = link
        } catch {
            githubDraft?.createProblem = error.localizedDescription
        }
    }

    var canAttachGitHubContext: Bool { agentSession?.isReadOnly != true && !busy }

    func attachGitHubComments(_ comments: [GitHubComment], for target: GitHubTarget) {
        guard githubBranchTarget == target, canAttachGitHubContext, !comments.isEmpty else { return }
        attachToAgent(comments.map(\.attachment))
    }

    func githubFailedLog(_ check: GitHubCheck, for target: GitHubTarget) async throws -> AgentContext {
        guard githubBranchTarget == target, canAttachGitHubContext,
              case let .ready(cli) = githubStatuses[target]?.access,
              let run = GitHubActionsRun(check: check, on: cli.repository.host) else {
            throw FolmiFailure(message: "当前无法读取这项检查的日志。")
        }
        let log = try await cli.failedLog(for: run)
        guard !log.isEmpty else { throw FolmiFailure(message: "没有可用的失败步骤日志。") }
        return AgentContext(title: "GitHub 检查 · \(check.title)", text: log)
    }
}
