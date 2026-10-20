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

    func preflightDelivery() {
        guard !busy, let repository, let root = repositoryURL else { return }
        do { _ = try makeDelivery() } catch { report(error, title: "交付参数无效"); return }
        let signature = formSignature, kind = deliveryKind, remote = deliveryRemote
        busy = true; deliveryPlan = nil
        Task {
            do {
                let current = try await repository.load()
                guard let head = current.head else { throw FolmiFailure(message: "项目还没有提交。") }
                snapshot = current
                var endpoint: String?
                if kind != .script {
                    _ = try await CommandRunner.git(["check-ref-format", "--branch", deliveryBranch.trimmingCharacters(in: .whitespacesAndNewlines)], at: root, environment: commandEnvironment)
                    endpoint = try await resolveEndpoint(root: root, remote: remote)
                }
                guard signature == formSignature, repositoryURL == root else { throw FolmiFailure(message: "交付参数已变化，请重新预检。") }
                let command = try makeDelivery(head: head, endpoint: endpoint)
                let executableFingerprint = kind == .script ? try ExecutableFingerprint.read(command.executable) : nil
                deliveryPlan = DeliveryPlan(root: root, head: head, fingerprint: current.fingerprint, formSignature: signature, kind: kind, endpoint: endpoint, command: command, executableFingerprint: executableFingerprint)
                record("交付预检通过", "已锁定提交 \(head)；尚未执行命令。")
            } catch { report(error, title: "交付预检失败") }
            busy = false
        }
    }

    func runDelivery() {
        guard canDeliver, let plan = deliveryPlan, let repository else { return }
        busy = true
        Task {
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
                let result = try await CommandRunner.run(plan.command, at: plan.root, environment: commandEnvironment)
                record(result.exitCode == 0 ? "交付命令完成" : "交付命令失败", "\(plan.command.display)\n\n锁定提交：\(plan.head)\n退出码：\(result.exitCode)\n\(result.combined)", isError: result.exitCode != 0)
                if result.exitCode != 0 { errorMessage = "交付命令退出码 \(result.exitCode)。本地提交仍然保留，详情见操作记录。" }
            } catch { report(error, title: "交付失败") }
            deliveryPlan = nil
            do { try await reload() } catch { report(error, title: "交付后刷新失败") }
            busy = false
        }
    }
}
