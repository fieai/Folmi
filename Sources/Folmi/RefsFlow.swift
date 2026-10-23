import AppKit
import FolmiCore
import SwiftUI

/// A branch or tag action waiting for a name or a confirmation.
enum RefPrompt: Identifiable, Equatable {
    case renameBranch(String)
    case deleteBranch(String, ownCommits: Bool)
    case createTag(commit: String)
    case deleteTag(String)

    var id: String {
        switch self {
        case .renameBranch(let name): return "rename:" + name
        case .deleteBranch(let name, _): return "delete:" + name
        case .createTag(let commit): return "tag:" + commit
        case .deleteTag(let name): return "untag:" + name
        }
    }
}

extension FolmiModel {
    func askDeleteBranch(_ branch: String) {
        guard let repository else { return }
        Task {
            do { refPrompt = .deleteBranch(branch, ownCommits: try await repository.branchHasOwnCommits(branch)) }
            catch { report(error, title: "无法删除分支") }
        }
    }

    func deleteBranch(_ branch: String) {
        guard let repository else { return }
        refPrompt = nil
        let title = "删除分支 \(branch)"
        mutate(title) { [weak self] in
            let step = try await repository.deleteBranch(branch)
            await MainActor.run { self?.pushUndo(title, step) }
            return "已删除分支 \(branch)。⌥⌘Z 可恢复。"
        }
    }

    func renameBranch(_ branch: String, to name: String) {
        guard let repository else { return }
        refPrompt = nil
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != branch else { return }
        let title = "分支改名 \(branch) → \(target)"
        mutate(title) { [weak self] in
            let step = try await repository.renameBranch(branch, to: target)
            await MainActor.run { self?.pushUndo(title, step) }
            return "分支 \(branch) 改名为 \(target)。远端上的同名分支不会跟着改。⌥⌘Z 可撤销。"
        }
    }

    func createTag(_ name: String, message: String, at commit: String) {
        guard let repository else { return }
        refPrompt = nil
        let tag = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        let title = "新建标签 \(tag)"
        mutate(title) { [weak self] in
            let step = try await repository.createTag(tag, at: commit, message: message)
            await MainActor.run { self?.pushUndo(title, step) }
            return "已在 \(commit.prefix(7)) 上打标签 \(tag)，还没推送。在提交上右键可以推送标签。"
        }
    }

    func deleteTag(_ name: String) {
        guard let repository else { return }
        refPrompt = nil
        let title = "删除标签 \(name)"
        mutate(title) { [weak self] in
            let step = try await repository.deleteTag(name)
            await MainActor.run { self?.pushUndo(title, step) }
            return "已删除本地标签 \(name)。远端的同名标签不受影响。⌥⌘Z 可恢复。"
        }
    }

    /// The remote tags go to: origin when there is one.
    var tagRemote: String? {
        guard let remotes = snapshot?.remotes, !remotes.isEmpty else { return nil }
        return remotes.contains("origin") ? "origin" : remotes.first
    }

    /// `git push <remote> refs/tags/<name>`; never forced, so a different tag of the same name on the remote stays.
    func pushTag(_ name: String) {
        guard let root = repositoryURL, let remote = tagRemote, !name.hasPrefix("-") else { return }
        let environment = commandEnvironment
        mutate("推送标签 \(name)") {
            let ref = "refs/tags/" + name
            let command = DeliveryCommand(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["push", "--", remote, ref + ":" + ref])
            let result = try await CommandRunner.run(command, at: root, environment: environment)
            guard result.exitCode == 0 else { throw FolmiFailure(message: "推送标签失败（退出码 \(result.exitCode)）\n\(result.combined)") }
            return "标签 \(name) 已推送到 \(remote)。"
        }
    }

    /// Adds the path to the root .gitignore; ⌥⌘Z takes the line out again.
    func ignorePath(_ path: String, folder: Bool) {
        guard let repository else { return }
        let pattern = GitRepository.ignorePattern(for: path, folder: folder)
        mutateUndoable("忽略 \(path)", capture: { try await repository.captureWorktree([".gitignore"]) }) {
            try await repository.addToGitignore(pattern)
            let tracked = try await repository.isTracked(path)
            return tracked
                ? "已把 \(pattern) 加进 .gitignore。不过它已经被 Git 跟踪，之后的改动仍会出现；要停止跟踪得先从仓库里删除它。"
                : "已把 \(pattern) 加进 .gitignore。"
        }
    }

    /// 新建文件 in the file tree: an empty file inside `folder`, opened in the editor. ⌥⌘Z deletes it again.
    func createFile(named name: String, in folder: String) {
        guard let repository else { return }
        let path: String
        do { path = try GitRepository.newFilePath(name, in: folder) } catch { report(error, title: "新建文件失败"); return }
        var created = false
        mutateUndoable("新建 \(path)", capture: { try await repository.captureWorktree([path]) },
                       succeeded: { created = true },
                       // `editPath` waits for the operation to finish, which happens right after `after`.
                       after: { [weak self] in if created { Task { self?.editPath(path) } } }) {
            try await repository.createFile(path)
            return "已新建 \(path)。⌥⌘Z 可撤销。"
        }
    }
}

/// The name boxes and confirmations for branch and tag actions, shown over the window.
struct RefPrompts: ViewModifier {
    @Bindable var model: FolmiModel
    @State private var name = ""
    @State private var message = ""

    private func binding(_ match: @escaping (RefPrompt) -> Bool) -> Binding<Bool> {
        Binding(get: { model.refPrompt.map(match) ?? false }, set: { if !$0 { model.refPrompt = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert("分支改名", isPresented: binding { if case .renameBranch = $0 { return true }; return false }) {
                TextField("新名字", text: $name)
                Button("改名") { if case .renameBranch(let branch) = model.refPrompt { model.renameBranch(branch, to: name) } }
                Button("取消", role: .cancel) { model.refPrompt = nil }
            } message: {
                if case .renameBranch(let branch) = model.refPrompt { Text("「\(branch)」改成什么？只改本地分支，远端不变。") }
            }
            .alert("新建标签", isPresented: binding { if case .createTag = $0 { return true }; return false }) {
                TextField("标签名，例如 v0.6.0", text: $name)
                TextField("说明（可不填）", text: $message)
                Button("新建") { if case .createTag(let commit) = model.refPrompt { model.createTag(name, message: message, at: commit) } }
                Button("取消", role: .cancel) { model.refPrompt = nil }
            } message: {
                if case .createTag(let commit) = model.refPrompt { Text("打在提交 \(commit.prefix(7)) 上。填了说明就是附注标签。") }
            }
            .confirmationDialog(deleteTitle, isPresented: binding {
                if case .deleteBranch = $0 { return true }; if case .deleteTag = $0 { return true }; return false
            }) {
                Button("删除", role: .destructive) {
                    switch model.refPrompt {
                    case .deleteBranch(let branch, _)?: model.deleteBranch(branch)
                    case .deleteTag(let tag)?: model.deleteTag(tag)
                    default: break
                    }
                }
                Button("取消", role: .cancel) { model.refPrompt = nil }
            } message: {
                switch model.refPrompt {
                case .deleteBranch(_, let own)?:
                    Text(own ? "这个分支上有别的分支和远端都没有的提交，删掉后只能用 ⌥⌘Z 找回。" : "它的提交别的分支或远端上都有，删掉不会丢东西。⌥⌘Z 可恢复。")
                default:
                    Text("只删本地标签，远端不变。⌥⌘Z 可恢复。")
                }
            }
            .onChange(of: model.refPrompt) { _, prompt in
                name = { if case .renameBranch(let branch) = prompt { return branch }; return "" }()
                message = ""
            }
    }

    private var deleteTitle: String {
        switch model.refPrompt {
        case .deleteBranch(let branch, _)?: return "删除分支「\(branch)」？"
        case .deleteTag(let tag)?: return "删除标签「\(tag)」？"
        default: return ""
        }
    }
}
