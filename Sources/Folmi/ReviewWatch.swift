import SwiftUI
import FolmiCore

/// A Gerrit review pushed from here, watched until it lands: after each background fetch, if its target branch moved
/// on, the commit is merged against the new tip locally (`git merge-tree`, nothing written, no request to Gerrit) to
/// see whether the review can still go in. A conflict shows a notice that leads to rebase and push again.
struct ReviewWatch: Codable, Equatable, Identifiable {
    var id: String { changeID ?? commit }
    var commit: String
    var changeID: String?
    var subject: String
    var remote: String
    var branch: String
    var pushed: Date
    /// The target tip last checked against, so an unchanged branch is not merged again.
    var checkedBase: String?
    /// Files that conflict with the target's latest; nil when it merges cleanly (or was not checked yet).
    var conflicts: [String]?

    /// Watches end after this long: a review left that long is dealt with on Gerrit.
    static let lifetime: TimeInterval = 30 * 24 * 3600
    static let limit = 20
}

extension FolmiModel {
    var reviewWatches: [ReviewWatch] {
        projects.first { $0.rootPath == repositoryURL?.path }?.reviewWatches ?? []
    }
    var conflictingReviews: [ReviewWatch] { reviewWatches.filter { $0.conflicts != nil } }

    private func updateWatches(_ root: URL, _ change: (inout [ReviewWatch]) -> Void) {
        guard let index = projects.firstIndex(where: { $0.rootPath == root.path }) else { return }
        var watches = projects[index].reviewWatches
        change(&watches)
        guard watches != projects[index].reviewWatches else { return }
        projects[index].reviewWatches = watches
        scheduleSave()
    }

    /// After a Gerrit push went through: watch this commit (a new patch set replaces the watch of its change).
    func watchReview(commit: String, remote: String, branch: String, root: URL) async {
        let message = (try? await CommandRunner.git(["log", "-1", "--format=%s%x00%B", commit], at: root, environment: commandEnvironment)) ?? ""
        let parts = message.components(separatedBy: "\0")
        let changeID = parts.dropFirst().first.flatMap { body in
            body.components(separatedBy: .newlines).last { $0.hasPrefix("Change-Id: I") }
                .map { String($0.dropFirst("Change-Id: ".count)).trimmingCharacters(in: .whitespaces) }
        }
        let watch = ReviewWatch(commit: commit, changeID: changeID, subject: parts.first ?? commit, remote: remote, branch: branch,
                                pushed: Date(), checkedBase: nil, conflicts: nil)
        updateWatches(root) { watches in
            watches.removeAll { $0.id == watch.id || $0.commit == commit }
            watches.insert(watch, at: 0)
            if watches.count > ReviewWatch.limit { watches.removeLast(watches.count - ReviewWatch.limit) }
        }
        refreshInReview()
    }

    /// Runs after each background fetch: drops reviews that landed or expired, and merges the others against their
    /// target's new tip, locally.
    func checkReviewWatches(root: URL) async {
        guard repositoryURL == root else { return }
        let watches = reviewWatches
        guard !watches.isEmpty else { return }
        let environment = commandEnvironment
        var updated: [ReviewWatch] = []
        for var watch in watches where Date().timeIntervalSince(watch.pushed) < ReviewWatch.lifetime {
            let current = watch
            let checked = await Task.detached(priority: .utility) { Self.check(current, root: root, environment: environment) }.value
            switch checked {
            case .landed: continue
            case .unknown: updated.append(watch)
            case let .checked(base, conflicts): watch.checkedBase = base; watch.conflicts = conflicts; updated.append(watch)
            }
        }
        guard repositoryURL == root else { return }
        updateWatches(root) { $0 = updated }
        refreshInReview()
    }

    enum ReviewCheck: Equatable { case landed, unknown, checked(base: String, conflicts: [String]?) }

    nonisolated static func check(_ watch: ReviewWatch, root: URL, environment: [String: String]) -> ReviewCheck {
        func git(_ arguments: [String]) -> (status: Int32, text: String)? {
            var env = ProcessInfo.processInfo.environment
            environment.forEach { env[$0.key] = $0.value }
            env["LC_ALL"] = "C"; env["GIT_TERMINAL_PROMPT"] = "0"
            guard let result = try? ProcessExecutor.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, directory: root,
                                                        environment: env, timeout: 30, stdoutLimit: 1024 * 1024, stderrLimit: 64 * 1024) else { return nil }
            return (result.status, String(decoding: result.stdout, as: UTF8.self))
        }
        guard let tip = git(["rev-parse", "--verify", "--quiet", "refs/remotes/\(watch.remote)/\(watch.branch)^{commit}"]), tip.status == 0 else { return .unknown }
        let base = tip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Landed: the commit itself is on the branch, or (cherry-picked / rebased by Gerrit) a commit with its Change-Id.
        if git(["merge-base", "--is-ancestor", watch.commit, base])?.status == 0 { return .landed }
        if let changeID = watch.changeID,
           let found = git(["log", "-1", "--format=%H", "--since=\(Int(watch.pushed.timeIntervalSince1970) - 86_400)", "--fixed-strings",
                            "--grep=Change-Id: \(changeID)", base]), found.status == 0,
           !found.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .landed }
        guard base != watch.checkedBase else { return .unknown }
        // The commit is gone (gc after a rebase elsewhere): nothing to merge.
        guard git(["cat-file", "-e", "\(watch.commit)^{commit}"])?.status == 0 else { return .unknown }
        guard let merged = git(["merge-tree", "--write-tree", "--name-only", "--no-messages", base, watch.commit]) else { return .unknown }
        switch merged.status {
        case 0: return .checked(base: base, conflicts: nil)
        case 1:
            // First line is the tree; the rest are the conflicted files.
            let files = merged.text.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
            return .checked(base: base, conflicts: Array(Set(files)).sorted())
        default: return .unknown
        }
    }

    /// Commits ahead of the upstream that are not waiting to be pushed: they went to Gerrit for review
    /// (`refs/for/…`), so the branch stays ahead until the review is merged.
    var unpushedCount: Int { max(0, (snapshot?.unpushed ?? 0) - inReviewCount) }

    /// Works out `inReviewCount` for the open project, off the main thread.
    func refreshInReview() {
        guard let root = repositoryURL else { inReviewCount = 0; return }
        let watches = reviewWatches, environment = commandEnvironment
        guard !watches.isEmpty, (snapshot?.ahead ?? 0) > 0 else { if inReviewCount != 0 { inReviewCount = 0 }; return }
        Task { [weak self] in
            let count = await Task.detached(priority: .utility) { Self.inReview(root: root, environment: environment, watches: watches) }.value
            guard let self, self.repositoryURL == root else { return }
            if self.inReviewCount != count { self.inReviewCount = count }
            if let snapshot = self.snapshot { self.board.patch(path: root.path, snapshot: snapshot, inReview: count) }
        }
    }

    /// How many commits between the upstream and HEAD a pushed review covers: a review's commit that HEAD still
    /// contains, counted from the upstream (pushing HEAD to refs/for/… puts every commit ahead up for review). Only
    /// reviews aimed at the branch's own upstream count.
    nonisolated static func inReview(root: URL, environment: [String: String], watches: [ReviewWatch]) -> Int {
        func git(_ arguments: [String]) -> (status: Int32, text: String)? {
            var env = ProcessInfo.processInfo.environment
            environment.forEach { env[$0.key] = $0.value }
            env["LC_ALL"] = "C"; env["GIT_TERMINAL_PROMPT"] = "0"
            guard let result = try? ProcessExecutor.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, directory: root,
                                                        environment: env, timeout: 15, stdoutLimit: 64 * 1024, stderrLimit: 16 * 1024) else { return nil }
            return (result.status, String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let upstream = git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]), upstream.status == 0 else { return 0 }
        var most = 0
        for watch in watches where "\(watch.remote)/\(watch.branch)" == upstream.text {
            guard git(["merge-base", "--is-ancestor", watch.commit, "HEAD"])?.status == 0,
                  let count = git(["rev-list", "--count", "@{upstream}..\(watch.commit)"]), count.status == 0 else { continue }
            most = max(most, Int(count.text) ?? 0)
        }
        return most
    }

    /// 变基并重新推送: the push sheet for this review's remote and branch; its button stops at the rebase choice.
    func redeliver(_ watch: ReviewWatch) {
        guard !busy else { return }
        deliveryKind = .gerrit; deliveryRemote = watch.remote; deliveryBranch = watch.branch
        prepareDelivery()
        preflightDelivery()
    }

    func dismissReviewWatch(_ watch: ReviewWatch) {
        guard let root = repositoryURL else { return }
        updateWatches(root) { $0.removeAll { $0.id == watch.id } }
    }
}

/// Above the change list while a pushed review no longer merges into its target branch.
struct ReviewConflictNotice: View {
    let model: FolmiModel
    let watch: ReviewWatch

    var body: some View {
        let onIt = model.snapshot?.head == watch.commit
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(ThemeColor(token: .modified))
                Text("评审和 \(watch.remote)/\(watch.branch) 冲突了").themedFont(.system(size: 12.5, weight: .semibold), points: 12.5)
            }
            Text("「\(watch.subject)」：\(watch.branch) 上的新提交和它改到了同样的地方（\((watch.conflicts ?? []).prefix(3).joined(separator: "、"))\((watch.conflicts?.count ?? 0) > 3 ? " 等" : "")），在 Gerrit 上合不进去。"
                 + (onIt ? "变基后推上去，会成为同一个评审的新补丁集。" : "本地已经不在这个提交上，切回它（或包含它的分支）再变基推送。"))
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if onIt {
                    Button("变基并重新推送…") { model.redeliver(watch) }.buttonStyle(.folmiProminent).controlSize(.small).disabled(model.busy)
                }
                Button("不再提醒") { model.dismissReviewWatch(watch) }.controlSize(.small)
                    .help("不再检查这个评审（比如已经在 Gerrit 上处理了）")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedBackground(ThemeColor(token: .modified, opacity: 0.08), .control)
        .overlay(RoundedRectangle(cornerRadius: model.theme.style.radius(.control), style: .continuous)
            .strokeBorder(ThemeColor(token: .modified, opacity: 0.35)))
    }
}
