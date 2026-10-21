import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// 交付: pushing or running a delivery script, with saved profiles and a preflight check.
extension FolmiModel {
    func prepareDelivery() { guard !busy, snapshot != nil else { return }; deliveryPlan = nil; showDelivery = true }

    func chooseScript() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "选择可执行的交付脚本"; panel.canChooseFiles = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { scriptPath = url.path }
    }

    func activateProfile(_ id: UUID?) {
        guard !busy else { return }
        if let profile = profiles.first(where: { $0.id == id }) { applyProfile(profile) }
        else { selectedProfileID = nil; profileName = ""; deliveryPlan = nil }
        scheduleSave()
    }

    func applyProfile(_ profile: DeliveryProfile) {
        selectedProfileID = profile.id; profileName = profile.name; deliveryKind = profile.kind
        deliveryRemote = profile.remote; deliveryBranch = profile.branch; scriptPath = profile.scriptPath; scriptArguments = profile.scriptArguments
    }

    func saveDeliveryProfile() {
        guard !busy, let index = projects.firstIndex(where: { $0.rootPath == repositoryURL?.path }) else { return }
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { report(FolmiFailure(message: "填写交付配置名称。"), title: "未保存配置"); return }
        let profile = DeliveryProfile(id: selectedProfileID ?? UUID(), name: name, kind: deliveryKind, remote: deliveryRemote, branch: deliveryBranch, scriptPath: scriptPath, scriptArguments: scriptArguments)
        if let old = projects[index].deliveryProfiles.firstIndex(where: { $0.id == profile.id }) { projects[index].deliveryProfiles[old] = profile }
        else { projects[index].deliveryProfiles.append(profile) }
        selectedProfileID = profile.id
        do { try savePreferencesNow(); record("交付配置已保存", "\(name)\n\(store.url.path)") } catch { report(error, title: "保存交付配置失败") }
    }

    func deleteDeliveryProfile() {
        guard !busy, let id = selectedProfileID, let index = projects.firstIndex(where: { $0.rootPath == repositoryURL?.path }) else { return }
        projects[index].deliveryProfiles.removeAll { $0.id == id }; selectedProfileID = nil; profileName = ""; deliveryPlan = nil
        do { try savePreferencesNow() } catch { report(error, title: "保存配置失败") }
    }

    func makeDelivery(head: String = "HEAD", endpoint: String? = nil) throws -> DeliveryCommand {
        guard let state = snapshot else { throw FolmiFailure(message: "先打开项目。") }
        guard state.head != nil else { throw FolmiFailure(message: "项目还没有提交。") }
        if deliveryKind == .script {
            let path = scriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { throw FolmiFailure(message: "选择一个有执行权限的脚本，使用绝对路径。") }
            return DeliveryCommand(executable: URL(fileURLWithPath: path), arguments: scriptArguments.components(separatedBy: .newlines).filter { !$0.isEmpty })
        }
        guard state.remotes.contains(deliveryRemote), !deliveryRemote.hasPrefix("-"), !deliveryRemote.isEmpty else { throw FolmiFailure(message: "请选择项目已有的远程。") }
        let branch = deliveryBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.hasPrefix("/"), !branch.hasSuffix("/"), !branch.hasSuffix("."), !branch.contains(".."), !branch.contains("//"), !branch.contains("@{"),
              !branch.contains(where: { $0.isWhitespace || $0.isNewline || "~^:?*[\\".contains($0) }),
              !branch.components(separatedBy: "/").contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".lock") }) else { throw FolmiFailure(message: "填写有效的目标分支名称，例如 main 或 feature/topic。") }
        let target = deliveryKind == .gerrit ? "refs/for/\(branch)" : "refs/heads/\(branch)"
        return DeliveryCommand(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["push", "--", endpoint ?? deliveryRemote, "\(head):\(target)"])
    }

    func resolveEndpoint(root: URL, remote: String) async throws -> String {
        let result = try await CommandRunner.git(["remote", "get-url", "--push", "--all", remote], at: root, environment: commandEnvironment)
        let urls = result.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard urls.count == 1, let value = urls.first, !value.contains("\0") else { throw FolmiFailure(message: "当前远程有零个或多个推送地址。请选择单一地址的远程，或使用明确的交付脚本。") }
        if let components = URLComponents(string: value), components.password != nil { throw FolmiFailure(message: "推送地址包含内嵌密码。请使用系统凭据或 SSH；工作台不会显示或保存该密码。") }
        return value
    }

    /// 预览命令 (scripts, or to look before a push): locks the commit and lists the command, runs nothing.
    func preflightDelivery() { Task { await planDelivery() } }

    /// The main button. A script runs the plan previewed before it. A push or a Gerrit review needs no separate
    /// preview: it is planned (commit locked, target fetched) and pushed in one go, unless the target branch moved on:
    /// then it stops with the plan on screen and the rebase choice, and the next click goes ahead.
    func deliver() {
        if deliveryKind == .script || (deliveryPlan?.rebaseNeeded == true && canDeliver) { runDelivery(); return }
        Task {
            guard let plan = await planDelivery(quiet: true), !plan.rebaseNeeded else { return }
            runDelivery()
        }
    }

    @discardableResult
    func planDelivery(quiet: Bool = false) async -> DeliveryPlan? {
        guard !busy, let repository, let root = repositoryURL else { return nil }
        do { _ = try makeDelivery() } catch { report(error, title: "交付参数无效"); return nil }
        let signature = formSignature, kind = deliveryKind, remote = deliveryRemote
        busy = true; deliveryPlan = nil
        defer { busy = false }
        do {
            var endpoint: String?
            var base: (name: String, commit: String)?, baseProblem: String?, behind = 0, missingChangeID = false
            if kind != .script {
                let branch = deliveryBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await CommandRunner.git(["check-ref-format", "--branch", branch], at: root, environment: commandEnvironment)
                endpoint = try await resolveEndpoint(root: root, remote: remote)
                // Before reading the state: the fetch moves a remote-tracking ref, which is part of the fingerprint.
                (base, baseProblem) = await fetchTarget(root: root, remote: remote, branch: branch)
            }
            let current = try await repository.load()
            guard let head = current.head else { throw FolmiFailure(message: "项目还没有提交。") }
            snapshot = current
            if kind != .script {
                if kind == .gerrit {
                    let message = try await CommandRunner.git(["log", "-1", "--format=%B", head], at: root, environment: commandEnvironment)
                    missingChangeID = !message.contains("Change-Id: I")
                }
                if let base {
                    behind = Int(try await CommandRunner.git(["rev-list", "--count", "\(head)..\(base.commit)"], at: root, environment: commandEnvironment)
                        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                }
            }
            guard signature == formSignature, repositoryURL == root else { throw FolmiFailure(message: "交付参数已变化，请重新预检。") }
            let command = try makeDelivery(head: head, endpoint: endpoint)
            let executableFingerprint = kind == .script ? try ExecutableFingerprint.read(command.executable) : nil
            let plan = DeliveryPlan(root: root, head: head, fingerprint: current.fingerprint, formSignature: signature, kind: kind, endpoint: endpoint, command: command,
                                    executableFingerprint: executableFingerprint, base: base, baseProblem: baseProblem, behind: behind, missingChangeID: missingChangeID)
            deliveryPlan = plan
            if !quiet || plan.rebaseNeeded { record("交付预检通过", "已锁定提交 \(head)；尚未执行命令。") }
            return plan
        } catch { report(error, title: "交付预检失败"); return nil }
    }

    /// Fetches just the target branch into its remote-tracking ref, so the plan knows what the remote has now. A branch
    /// the remote does not have yet, or a fetch that fails, is not an error: the plan says so and pushes as before.
    func fetchTarget(root: URL, remote: String, branch: String) async -> ((name: String, commit: String)?, String?) {
        let tracking = "refs/remotes/\(remote)/\(branch)"
        let fetch = DeliveryCommand(executable: URL(fileURLWithPath: "/usr/bin/git"),
                                    arguments: ["-c", "gc.auto=0", "fetch", "--quiet", "--no-tags", "--", remote, "+refs/heads/\(branch):\(tracking)"])
        var environment = commandEnvironment
        environment["GIT_ASKPASS"] = "/usr/bin/false"; environment["SSH_ASKPASS"] = "/usr/bin/false"
        guard let result = try? await CommandRunner.run(fetch, at: root, environment: environment, timeout: 60) else {
            return (nil, "没能从 \(remote) 取回 \(branch)，没有检查远端是否有新提交")
        }
        guard result.exitCode == 0 else {
            if result.error.contains("couldn't find remote ref") { return (nil, "\(remote) 上还没有 \(branch) 分支") }
            return (nil, "没能从 \(remote) 取回 \(branch)，没有检查远端是否有新提交")
        }
        guard let commit = try? await CommandRunner.git(["rev-parse", "--verify", "\(tracking)^{commit}"], at: root, environment: commandEnvironment) else {
            return (nil, "没能读到 \(remote)/\(branch)")
        }
        return (("\(remote)/\(branch)", commit.trimmingCharacters(in: .whitespacesAndNewlines)), nil)
    }

    /// The review links Gerrit prints after a push ("remote:   https://…/c/project/+/123 subject [NEW]").
    static func reviewLinks(_ output: String) -> [String] {
        output.components(separatedBy: .newlines).filter { $0.hasPrefix("remote:") }.compactMap { line in
            line.range(of: #"https?://\S+"#, options: .regularExpression).map { String(line[$0]) }
        }
    }

    func runDelivery() {
        guard canDeliver, let plan = deliveryPlan, let repository else { return }
        let rebaseFirst = plan.rebaseNeeded && deliveryRebaseFirst
        busy = true
        Task {
            var delivered = false
            do {
                let current = try await repository.load()
                guard current.fingerprint == plan.fingerprint, current.head == plan.head, repositoryURL == plan.root, formSignature == plan.formSignature else { throw FolmiFailure(message: "项目、文件或提交在预检后发生变化。请重新预检，不能直接执行旧计划。") }
                if plan.kind != .script {
                    let endpoint = try await resolveEndpoint(root: plan.root, remote: deliveryRemote)
                    guard endpoint == plan.endpoint else { throw FolmiFailure(message: "远程推送地址已变化，请重新预检。") }
                }
                if let expected = plan.executableFingerprint,
                   try ExecutableFingerprint.read(plan.command.executable) != expected {
                    throw FolmiFailure(message: "交付脚本在预检后发生变化，请重新检查脚本并预检。")
                }
                var command = plan.command, head = plan.head
                if rebaseFirst, let base = plan.base {
                    let branch = try await repository.currentBranchRef()
                    switch try await repository.rebase(onto: base.commit, expectedFingerprint: plan.fingerprint, expectedHead: plan.head) {
                    case let .done(before, after):
                        pushUndo("变基到 \(base.name)", .reset(restore: before, current: after, branch: branch))
                        record("变基到 \(base.name)", "\(before.prefix(7)) → \(after.prefix(7))，取进 \(plan.behind) 个远端提交。⌥⌘Z 可回到变基前。")
                        head = after
                        command = try makeDelivery(head: after, endpoint: plan.endpoint)
                    case let .conflict(operation, files):
                        // Finish the rebase in the change list; the sheet comes back once it is done.
                        pullStartHeads[plan.root.path] = PullStart(head: plan.head, branch: branch)
                        deliveryAfterRebase.insert(plan.root.path)
                        showDelivery = false
                        showSideTab(.changes)
                        errorMessage = Self.conflictHelp(operation, files: files) + "\n\n变基完成后会重新打开「推送到远端」。"
                        throw FolmiFailure(message: "变基到 \(base.name) 时有冲突，停在中途：\n" + files.joined(separator: "\n"))
                    }
                }
                let result = try await CommandRunner.run(command, at: plan.root, environment: commandEnvironment)
                let review = plan.kind == .gerrit ? Self.reviewLinks(result.combined) : []
                let title = result.exitCode != 0 ? "交付命令失败" : plan.kind == .gerrit ? "已提交 Gerrit 评审" : "交付命令完成"
                record(title, (review.isEmpty ? "" : review.joined(separator: "\n") + "\n\n")
                       + "\(command.display)\n\n锁定提交：\(head)\n退出码：\(result.exitCode)\n\(result.combined)", isError: result.exitCode != 0)
                if result.exitCode != 0 { errorMessage = "交付命令退出码 \(result.exitCode)。本地提交仍然保留，详情见操作记录。" }
                delivered = result.exitCode == 0
                if delivered, plan.kind == .gerrit { await watchReview(commit: head, remote: deliveryRemote, branch: deliveryBranch.trimmingCharacters(in: .whitespacesAndNewlines), root: plan.root) }
            } catch { if !deliveryAfterRebase.contains(plan.root.path) { report(error, title: "交付失败") } else { record("交付暂停", error.localizedDescription, isError: true) } }
            if delivered { showDelivery = false }
            deliveryPlan = nil
            do { try await reload() } catch { report(error, title: "交付后刷新失败") }
            busy = false
        }
    }
}
