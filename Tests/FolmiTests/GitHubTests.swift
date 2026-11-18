import Foundation
import SwiftUI
import XCTest
import FolmiCore
@testable import Folmi

final class GitHubCLITests: XCTestCase {
    func testRemoteFormatsAndInstallOrLoginReasons() async throws {
        let fixture = try GitHubFixture()
        defer { fixture.remove() }
        for remote in ["https://github.com/team/app.git", "git@GitHub.com:team/app.git", "ssh://git@ssh.github.com:443/team/app"] {
            XCTAssertEqual(GitHubRepository(remote: remote)?.argument, "github.com/team/app")
        }
        XCTAssertNil(GitHubRepository(remote: "/tmp/team/app.git"))
        XCTAssertNil(GitHubRepository(remote: "ssh://git@example.test/team/dept/app"))
        XCTAssertEqual(GitHubRepository(remote: "git@ghe.example.test:user_corp/app.git.git")?.argument, "ghe.example.test/user_corp/app.git")

        let missing = try await GitHubCLI.access(remote: fixture.remote, at: fixture.dir, locate: { nil })
        guard case let .unavailable(reason, command) = missing else { return XCTFail("expected install help") }
        XCTAssertTrue(reason.contains("安装"))
        XCTAssertEqual(command, "brew install gh")
        XCTAssertTrue(try fixture.calls().isEmpty)

        try fixture.write("logged-out", "")
        guard case let .unavailable(loginReason, loginCommand) = try await fixture.access(),
              case .otherRemote = try await fixture.access("ssh://git@gerrit.example.test/team/app") else {
            return XCTFail("expected login help only for GitHub")
        }
        XCTAssertTrue(loginReason.contains("登录"))
        XCTAssertEqual(loginCommand, "gh auth login")
        try fixture.delete("logged-out")
        guard case let .ready(cli) = try await fixture.access("ssh://git@ghe.example.test/team/app.git") else {
            return XCTFail("expected GitHub Enterprise")
        }
        XCTAssertEqual(cli.repository.argument, "ghe.example.test/team/app")
        XCTAssertTrue(try fixture.calls().contains("auth|status|--hostname|ghe.example.test"))
    }

    func testCreatePassesLiteralArgumentsAndBodyThroughStdin() async throws {
        let fixture = try GitHubFixture()
        defer { fixture.remove() }
        let cli = try await fixture.cli()
        let title = "看一下 '引号' $(touch marker)"
        let body = "第一行\n第二行\n\n"
        let link = try await cli.createPullRequest(branch: "feat/new-pr", base: "release/latest", title: title, body: body, draft: true)
        XCTAssertEqual(link.number, 42)
        XCTAssertEqual(link.url.absoluteString, "https://github.com/team/app/pull/42")
        XCTAssertEqual(try fixture.read("body"), body)
        XCTAssertTrue(try fixture.calls().contains("pr|create|--repo|github.com/team/app|--head|feat/new-pr|--base|release/latest|--title|\(title)|--body-file|-|--draft"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.dir.appendingPathComponent("marker").path))
    }

    func testOpenPRStatusHandlesNumericBranchesClosedPRsAndMissingPRs() async throws {
        let fixture = try GitHubFixture()
        defer { fixture.remove() }
        let cli = try await fixture.cli()
        let absent = try await cli.openPullRequest(branch: "feat/new-pr")
        XCTAssertNil(absent)
        try fixture.write("open", "")
        let numeric = try await cli.openPullRequest(branch: "123")
        XCTAssertEqual(numeric?.number, 42)
        XCTAssertTrue(try fixture.calls().contains("pr|list|--repo|github.com/team/app|--state|open|--head|123"))
        try fixture.write("closed", "")
        let closed = try await cli.openPullRequest(branch: "feat/new-pr")
        XCTAssertNil(closed)
        try fixture.write("pr-error", "")
        do {
            _ = try await cli.openPullRequest(branch: "feat/new-pr")
            XCTFail("expected rate limit error")
        } catch { XCTAssertEqual(error.localizedDescription, "rate limited") }
    }

    func testReviewPaginationChecksAndStaleLineWarning() async throws {
        let fixture = try GitHubFixture()
        defer { fixture.remove() }
        try fixture.write("open", "")
        let cli = try await fixture.cli()
        let result = try await cli.openPullRequest(branch: "feat/new-pr")
        let pr = try XCTUnwrap(result)
        let comments = try await cli.unresolvedComments(number: pr.number)
        XCTAssertEqual(pr.statusTitle, "评审要求修改")
        XCTAssertEqual(pr.failedChecks.map(\.title), ["macOS", "External CI"])
        XCTAssertEqual(pr.capsuleTitle(comments: comments), "PR #42 · 2 项检查失败 · 3 条评论没解决")
        XCTAssertEqual(pr.capsuleTitle(comments: nil), "PR #42 · 2 项检查失败")
        XCTAssertEqual(comments.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(comments.map(\.location), ["one.swift:5", "one.swift:5", "two.swift:7"])
        XCTAssertEqual(comments.map(\.author), ["alice", "未知用户", "bob"])
        XCTAssertEqual(comments[0].attachment.text, "文件：one.swift:5\n评论人：alice\n\n先处理这行。\n保持原文。")
        XCTAssertFalse(comments[0].locationMayHaveChanged(localHead: pr.headRefOid, pullRequestHead: pr.headRefOid))
        XCTAssertTrue(comments[0].locationMayHaveChanged(localHead: "different", pullRequestHead: pr.headRefOid))
        XCTAssertTrue(comments[2].locationMayHaveChanged(localHead: pr.headRefOid, pullRequestHead: pr.headRefOid))
        XCTAssertEqual(GitHubStatusBadge.ageTitle(Date(timeIntervalSince1970: 100), now: Date(timeIntervalSince1970: 281)), "3 分钟前")
        XCTAssertTrue(try fixture.calls().contains("owner=team|"))
        XCTAssertTrue(try fixture.calls().contains("cursor=more-threads"))
        XCTAssertTrue(try fixture.calls().contains("cursor=more-replies"))
    }

    func testActionsLogsKeepTheLast200LinesBeyondTheProcessLimit() async throws {
        let fixture = try GitHubFixture()
        defer { fixture.remove() }
        try fixture.write("open", "")
        try fixture.write("long-log", "")
        let cli = try await fixture.cli()
        let result = try await cli.openPullRequest(branch: "feat/new-pr")
        let checks = try XCTUnwrap(result).failedChecks
        let run = try XCTUnwrap(GitHubActionsRun(check: checks[0], on: "github.com"))
        XCTAssertNil(GitHubActionsRun(check: checks[1], on: "github.com"))
        let log = try await cli.failedLog(for: run)
        let lines = log.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 200)
        XCTAssertEqual(lines.first, "line 41")
        XCTAssertEqual(lines.last, "line 240")
        XCTAssertEqual(GitHubCLI.lastLogLines("A\r\n\r\nB\r\n"), "A\n\nB")
        XCTAssertTrue(try fixture.calls().contains("run|view|99|--repo|github.com/team/app|--log-failed"))
    }
}

final class GitHubFlowTests: XCTestCase {
    @MainActor
    func testPushThenCreateRetainsDraftAndGitStateOnFailure() async throws {
        let fixture = try GitHubFixture()
        defer { fixture.remove() }
        let model = try await fixture.model()
        let root = try XCTUnwrap(model.repositoryURL)
        let initial = try XCTUnwrap(model.snapshot)
        XCTAssertTrue(try fixture.calls().isEmpty)

        model.prepareDelivery()
        try await wait("delivery lookup") { model.githubDeliveryStatus?.checkedAt != nil }
        let target = try XCTUnwrap(model.githubDeliveryTarget)
        XCTAssertEqual(target.branch, "feat/new-pr")
        let status = try XCTUnwrap(model.githubDeliveryStatus)
        XCTAssertTrue(status.canCreate(branch: target.branch))
        XCTAssertFalse(status.canCreate(branch: "main"))
        XCTAssertNil(model.visibleGitHubDraft)

        try fixture.write("reject-push", "")
        model.pushForGitHubPullRequest()
        try await wait("failed push") { !model.busy && model.currentActivity.contains(where: { $0.title == "交付命令失败" }) }
        XCTAssertNil(model.visibleGitHubDraft)
        XCTAssertFalse(try fixture.calls().contains("pr|create"))

        try fixture.delete("reject-push")
        model.pushForGitHubPullRequest()
        try await wait("successful push and draft") { !model.busy && model.visibleGitHubDraft != nil }
        let draft = try XCTUnwrap(model.visibleGitHubDraft)
        XCTAssertTrue(model.showDelivery)
        XCTAssertEqual(draft.title, "更新一份文件")
        XCTAssertEqual(draft.body, "## 新提交\n\n- 更新一份文件\n\n改动文件数：1")
        XCTAssertEqual(draft.base, "main")
        XCTAssertFalse(draft.isDraft)
        try fixture.write("logged-out", "")
        await model.refreshGitHubForDelivery()
        XCTAssertFalse(model.canSubmitGitHubDraft)
        await model.createGitHubPullRequest()
        try fixture.delete("logged-out")
        await model.refreshGitHubForDelivery()
        XCTAssertTrue(model.canSubmitGitHubDraft)
        model.githubDraft?.base = "bad:branch"
        XCTAssertEqual(model.visibleGitHubDraft?.canSubmit, false)
        await model.createGitHubPullRequest()
        model.githubDraft?.base = "main"
        let pushed = try await fixture.remoteHead(from: root)
        XCTAssertEqual(pushed, initial.head)
        XCTAssertFalse(try fixture.calls().contains("pr|create"))

        model.githubDraft?.title = "用户改过的标题"
        model.githubDraft?.body = "详细描述\n原样保留"
        model.githubDraft?.isDraft = true
        try fixture.write("reject-create", "")
        await model.createGitHubPullRequest()
        XCTAssertTrue(model.visibleGitHubDraft?.createProblem?.contains("PR 创建被拒绝") == true)
        XCTAssertEqual(model.visibleGitHubDraft?.title, "用户改过的标题")
        XCTAssertEqual(model.visibleGitHubDraft?.body, "详细描述\n原样保留")
        XCTAssertEqual(model.visibleGitHubDraft?.isDraft, true)
        let afterCreateFailure = try await fixture.remoteHead(from: root)
        XCTAssertEqual(afterCreateFailure, initial.head)

        try fixture.delete("reject-create")
        await model.createGitHubPullRequest()
        XCTAssertEqual(model.visibleGitHubDraft?.created?.number, 42)
        XCTAssertEqual(model.githubDeliveryStatus?.pushTitle, "推送（更新 PR #42）")
        XCTAssertEqual(model.githubDeliveryStatus?.comments?.count, 3)
        XCTAssertEqual(try fixture.read("body"), "详细描述\n原样保留")
        XCTAssertEqual(model.snapshot?.head, initial.head)
        XCTAssertEqual(model.snapshot?.files.map(\.path), initial.files.map(\.path))
        let calls = try fixture.calls()
        XCTAssertTrue(calls.contains("|--|42"))
        let afterCreate = calls.components(separatedBy: "pr|create").count
        await model.createGitHubPullRequest()
        XCTAssertEqual(try fixture.calls().components(separatedBy: "pr|create").count, afterCreate)
    }

    @MainActor
    func testFirstDisplayOnlyAndUserRefreshLeaveBackgroundFetchDisconnected() async throws {
        let fixture = try GitHubFixture()
        defer { fixture.remove() }
        let model = try await fixture.model()
        defer { model.terminalSession?.stop() }
        let target = try XCTUnwrap(model.githubBranchTarget)
        try fixture.write("open", "")
        await model.showGitHubStatusOnFirstChangesDisplay()
        let firstCalls = try fixture.calls()
        XCTAssertTrue(firstCalls.contains("pr|view"))
        await model.showGitHubStatusOnFirstChangesDisplay()
        await model.fetchNow(root: target.root)
        try await wait("background refresh") { model.lastFetch != nil }
        XCTAssertEqual(try fixture.calls(), firstCalls)

        let status = try XCTUnwrap(model.githubStatuses[target])
        let comments = try XCTUnwrap(status.comments)
        model.agentDraft = "先保留我的草稿"
        model.attachGitHubComments(Array(comments.prefix(2)), for: target)
        model.attachGitHubComments(Array(comments.prefix(2)), for: target)
        XCTAssertEqual(model.agentDraft, "先保留我的草稿")
        XCTAssertEqual(model.agentContext.map(\.text), comments.prefix(2).map { $0.attachment.text })
        XCTAssertEqual(model.agentSession?.transcript.entries.count, 0)

        let pr = try XCTUnwrap(status.pullRequest)
        let context = try await model.githubFailedLog(pr.failedChecks[0], for: target)
        XCTAssertEqual(context.title, "GitHub 检查 · macOS")
        XCTAssertTrue(context.text.hasSuffix("line 240"))
        XCTAssertEqual(model.agentSession?.transcript.entries.count, 0)

        try fixture.write("pr-error", "")
        await model.refreshGitHub(target)
        XCTAssertEqual(model.githubStatuses[target]?.checkedAt, status.checkedAt)
        XCTAssertEqual(model.githubStatuses[target]?.pullRequest?.number, 42)
        XCTAssertEqual(model.githubStatuses[target]?.comments, comments)
        XCTAssertTrue(model.githubStatuses[target]?.problem?.contains("rate limited") == true)
        try fixture.delete("pr-error")
        try fixture.write("closed", "")
        await model.refreshGitHub(target)
        XCTAssertNil(model.githubStatuses[target]?.pullRequest)
    }

    @MainActor
    func testPushRefreshesWithoutCreatingAndReadsMultiCommitFallback() async throws {
        let fixture = try GitHubFixture()
        defer { fixture.remove() }
        let model = try await fixture.model(commits: 2)
        model.prepareDelivery()
        try await wait("delivery lookup") { model.githubDeliveryStatus?.checkedAt != nil }
        model.pushForGitHubPullRequest()
        try await wait("multi-commit draft") { !model.busy && model.visibleGitHubDraft != nil }
        XCTAssertEqual(model.visibleGitHubDraft?.title, "feat/new-pr")
        XCTAssertEqual(model.visibleGitHubDraft?.body, "## 新提交\n\n- 增加第二次提交\n- 更新一份文件\n\n改动文件数：2")
        model.githubDraft = nil
        try fixture.write("open", "")
        model.deliver()
        try await wait("ordinary push refreshed the PR") { !model.busy && model.githubDeliveryStatus?.pullRequest?.number == 42 }
        XCTAssertFalse(model.showDelivery)
        XCTAssertNil(model.visibleGitHubDraft)
        XCTAssertFalse(try fixture.calls().contains("pr|create"))
    }

    @MainActor
    func testCreateVariantStopsAtRebaseChoiceBeforePushing() async throws {
        let fixture = try GitHubFixture()
        defer { fixture.remove() }
        let model = try await fixture.model(remoteAhead: true)
        let root = try XCTUnwrap(model.repositoryURL)
        let before = try await fixture.remoteHead(from: root)
        model.prepareDelivery()
        try await wait("delivery lookup") { model.githubDeliveryStatus?.checkedAt != nil }
        model.pushForGitHubPullRequest()
        try await wait("rebase choice") { !model.busy && model.deliveryPlan?.rebaseNeeded == true }
        let stopped = try await fixture.remoteHead(from: root)
        XCTAssertEqual(stopped, before)
        XCTAssertNil(model.visibleGitHubDraft)
        model.pushForGitHubPullRequest()
        try await wait("push after rebase") { !model.busy && model.visibleGitHubDraft != nil }
        let pushed = try await fixture.remoteHead(from: root)
        XCTAssertNotEqual(pushed, before)
        XCTAssertEqual(model.snapshot?.head, pushed)
        XCTAssertTrue(model.visibleGitHubDraft?.body.contains("改动文件数：2") == true)
        XCTAssertFalse(try fixture.calls().contains("pr|create"))
    }

    func testSuggestedTitleUsesCommitSubjectsAndPreservesEdits() async throws {
        let fixture = try GitHubFixture()
        defer { fixture.remove() }
        let cli = try await fixture.cli()
        let target = GitHubTarget(root: fixture.dir, remote: "origin", branch: "feat/new-pr")
        var draft = GitHubDraft(target: target, endpoint: fixture.remote, cli: cli, base: "main", title: target.branch)
        let prompt = GitHubDraft.titlePrompt(subjects: ["更新一份文件", "增加第二次提交"], paths: ["one.swift"])
        XCTAssertEqual(prompt?.user, "更新一份文件\n增加第二次提交")
        XCTAssertTrue(prompt?.system.contains("in Chinese") == true)
        XCTAssertNil(GitHubDraft.titlePrompt(subjects: ["Update settings"], paths: [".env"]))
        draft.applySuggestedTitle("```\n合并两项改动\n\n更多说明\n```", replacing: target.branch)
        XCTAssertEqual(draft.title, "合并两项改动")
        draft.title = "我写的标题"
        draft.applySuggestedTitle("建议标题", replacing: target.branch)
        XCTAssertEqual(draft.title, "我写的标题")
    }

    @MainActor
    func testDeliverySheetDrawsLoginHelpAndExistingPR() async throws {
        let fixture = try GitHubFixture()
        defer { fixture.remove() }
        let model = try await fixture.model()
        try fixture.write("logged-out", "")
        model.prepareDelivery()
        try await wait("login help") {
            if case .unavailable = model.githubDeliveryStatus?.access { return true }
            return false
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 650, height: 730),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: DeliverySheet(model: model))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(300))
        let login = try ScreenText.read(hosting)
        XCTAssertTrue(login.contains("gh auth login"), login)

        try fixture.delete("logged-out")
        try fixture.write("open", "")
        await model.refreshGitHubForDelivery()
        try await Task.sleep(for: .milliseconds(300))
        let pr = try ScreenText.read(hosting).replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(pr.contains("更新PR#42"), pr)
        XCTAssertTrue(pr.contains("在浏览器打开PR#42"), pr)
    }

    @MainActor
    private func wait(_ description: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        if !condition() { throw FolmiFailure(message: "等待超时：\(description)") }
    }
}

private struct GitHubFixture {
    let dir: URL
    let gh: URL
    let remote = "git@github.com:team/app.git"

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-FakeGitHub-\(UUID().uuidString)", isDirectory: true)
        gh = dir.appendingPathComponent("gh")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try executable("gh", Self.ghScript)
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
    func write(_ path: String, _ text: String) throws { try text.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8) }
    func delete(_ path: String) throws { try FileManager.default.removeItem(at: dir.appendingPathComponent(path)) }
    func read(_ path: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8) }
    func calls() throws -> String { FileManager.default.fileExists(atPath: dir.appendingPathComponent("calls").path) ? try read("calls") : "" }

    private func executable(_ path: String, _ script: String) throws {
        try write(path, script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.appendingPathComponent(path).path)
    }

    func access(_ remote: String? = nil) async throws -> GitHubAccess {
        try await GitHubCLI.access(remote: remote ?? self.remote, at: dir, locate: { [gh] in gh })
    }
    func cli() async throws -> GitHubCLI {
        guard case let .ready(cli) = try await access() else { throw FolmiFailure(message: "fake gh unavailable") }
        return cli
    }

    private var environment: [String: String] {
        ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
         "GIT_ALLOW_PROTOCOL": "file:ssh", "GIT_SSH_VARIANT": "simple", "GIT_SSH_COMMAND": "'\(dir.appendingPathComponent("ssh").path)'"]
    }

    @MainActor
    func model(commits: Int = 1, remoteAhead: Bool = false) async throws -> FolmiModel {
        try executable("ssh", Self.sshScript)
        let work = dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        _ = try await git(["init", "--bare", dir.appendingPathComponent("remote.git").path], at: dir)
        _ = try await git(["init", "-b", "main"], at: work)
        _ = try await git(["config", "user.name", "Folmi Tests"], at: work)
        _ = try await git(["config", "user.email", "folmi@example.test"], at: work)
        try write("work/one.swift", "initial\n")
        _ = try await git(["add", "one.swift"], at: work)
        _ = try await git(["commit", "-m", "Base"], at: work)
        try await write("base", git(["rev-parse", "HEAD"], at: work) + "\n")
        _ = try await git(["remote", "add", "origin", remote], at: work)
        _ = try await git(["push", "--", "origin", "HEAD:refs/heads/main"], at: work)
        _ = try await git(["switch", "-c", "feat/new-pr"], at: work)
        try write("work/one.swift", "line one\nline two\n")
        _ = try await git(["commit", "-am", "更新一份文件"], at: work)
        if commits == 2 {
            try write("work/two.swift", "line three\n")
            _ = try await git(["add", "two.swift"], at: work)
            _ = try await git(["commit", "-m", "增加第二次提交"], at: work)
        }
        if remoteAhead {
            _ = try await git(["switch", "-c", "peer", "main"], at: work)
            try write("work/peer.swift", "updated remotely\n")
            _ = try await git(["add", "peer.swift"], at: work)
            _ = try await git(["commit", "-m", "同事提交"], at: work)
            _ = try await git(["push", "--", "origin", "HEAD:refs/heads/feat/new-pr"], at: work)
            _ = try await git(["switch", "feat/new-pr"], at: work)
        } else {
            try write("work/one.swift", "keep workspace content\n")
        }
        let model = FolmiModel(store: WorkspaceStore(url: dir.appendingPathComponent("workspace.json")), locateGitHubCLI: { [gh] in gh })
        model.aiSettings = AISettings()
        model.open(work, environment: environment)
        let deadline = Date().addingTimeInterval(12)
        while model.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard model.snapshot != nil else { throw FolmiFailure(message: model.errorMessage ?? "无法打开测试仓库") }
        return model
    }

    func remoteHead(from root: URL) async throws -> String {
        try await git(["--git-dir", dir.appendingPathComponent("remote.git").path, "rev-parse", "refs/heads/feat/new-pr"], at: root)
    }

    private func git(_ args: [String], at root: URL) async throws -> String {
        try await CommandRunner.git(args, at: root, environment: environment).trimmingCharacters(in: .newlines)
    }

    private static let sshScript = #"""
        #!/bin/sh
        dir=${0%/*}
        [ "$1" = git@github.com ] || exit 90
        case "$2" in
          "git-upload-pack "*) exec /usr/bin/git-upload-pack "$dir/remote.git" ;;
          "git-receive-pack "*) [ ! -f "$dir/reject-push" ] || exit 91
                              exec /usr/bin/git-receive-pack "$dir/remote.git" ;;
          *) exit 92 ;;
        esac
        """#

    private static let ghScript = #"""
        #!/bin/sh
        set -eu
        dir=${0%/*}
        [ "$GH_PROMPT_DISABLED" = 1 ] && [ "$GH_NO_UPDATE_NOTIFIER" = 1 ] && [ "$NO_COLOR" = 1 ] || exit 93
        (IFS='|'; printf '%s\n' "$*") >> "$dir/calls"
        case "$1 $2" in
          'auth status')
            [ "$3" = '--hostname' ]
            if [ -f "$dir/logged-out" ]; then printf 'You are not logged into this host.\n' >&2; exit 1; fi
            case "$4" in github.com|ghe.example.test) ;; *) exit 1;; esac ;;
          'repo view') printf '%s\n' '{"defaultBranchRef":{"name":"main"}}' ;;
          'api repos/team/app/git/ref/heads/main') /bin/cat "$dir/base" ;;
          'pr list') printf '%s\n' '[{"number":17,"isCrossRepository":true},{"number":42,"isCrossRepository":false}]' ;;
          'pr view')
            if [ -f "$dir/pr-error" ]; then printf 'rate limited\n' >&2; exit 1; fi
            if [ ! -f "$dir/open" ]; then printf 'no pull requests found for branch "feat/new-pr"\n' >&2; exit 1; fi
            state=OPEN; [ ! -f "$dir/closed" ] || state=MERGED
            printf '%s\n' "{\"number\":42,\"title\":\"看这份改动\",\"url\":\"https://github.com/team/app/pull/42\",\"state\":\"$state\",\"isDraft\":false,\"reviewDecision\":\"CHANGES_REQUESTED\",\"headRefOid\":\"abc123\",\"statusCheckRollup\":[{\"name\":\"macOS\",\"conclusion\":\"FAILURE\",\"detailsUrl\":\"https://github.com/team/app/actions/runs/99/job/7\"},{\"context\":\"External CI\",\"state\":\"ERROR\",\"targetUrl\":\"https://ci.example.test/runs/1\"},{\"name\":\"lint\",\"conclusion\":\"SUCCESS\"}]}" ;;
          'pr create')
            /bin/cat > "$dir/body"
            if [ -f "$dir/reject-create" ]; then printf 'PR 创建被拒绝\n' >&2; exit 1; fi
            /usr/bin/touch "$dir/open"
            printf 'https://github.com/team/app/pull/42\n' ;;
          'api graphql')
            case "$*" in
              *cursor=more-replies*) printf '%s\n' '{"data":{"node":{"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"c2","author":null,"body":"This is a reply."}]}}}}' ;;
              *cursor=more-threads*) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"t3","isResolved":false,"isOutdated":true,"path":"two.swift","line":null,"originalLine":7,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"c3","author":{"login":"bob"},"body":"Old location."}]}}]}}}}}' ;;
              *) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"more-threads"},"nodes":[{"id":"t1","isResolved":false,"isOutdated":false,"path":"one.swift","line":5,"originalLine":4,"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"more-replies"},"nodes":[{"id":"c1","author":{"login":"alice"},"body":"先处理这行。\n保持原文。"}]}},{"id":"t2","isResolved":true,"isOutdated":false,"path":"one.swift","line":10,"originalLine":10,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"resolved","author":{"login":"alice"},"body":"Done."}]}}]}}}}}' ;;
            esac ;;
          'run view')
            if [ -f "$dir/long-log" ]; then /bin/dd if=/dev/zero bs=65536 count=75 2>/dev/null; printf '\n'; fi
            /usr/bin/awk 'BEGIN { for (i=1; i<=240; i++) printf "line %d\n", i }' ;;
          *) exit 94 ;;
        esac
        """#
}
