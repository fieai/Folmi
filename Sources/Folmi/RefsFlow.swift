import AppKit
import FolmiCore
import SwiftUI

/// A Git action waiting for a name or confirmation.
enum RefPrompt: Identifiable, Equatable {
    case createAndSwitch
    case trackBranch(RemoteBranch)
    case renameBranch(String)
    case deleteBranch(String, ownCommits: Bool)
    case createTag(commit: String)
    case deleteTag(String)
    case ignoreTracked(path: String, fingerprint: String, blocker: String?)

    var id: String {
        switch self {
        case .createAndSwitch: return "new-branch"
        case .trackBranch(let remote): return "track:" + remote.id
        case .renameBranch(let name): return "rename:" + name
        case .deleteBranch(let name, _): return "delete:" + name
        case .createTag(let commit): return "tag:" + commit
        case .deleteTag(let name): return "untag:" + name
        case .ignoreTracked(let path, _, _): return "ignore:" + path
        }
    }
}

extension FolmiModel {
    var branchSwitchBlocker: String? {
        if editorWorkspace?.hasUnsavedChanges == true { return "先保存编辑器里的改动，再切换分支。" }
        if snapshot?.operation != nil || snapshot?.files.contains(where: \.isConflict) == true {
            return "先完成当前的冲突处理，再切换分支。"
        }
        return nil
    }

    var newBranchBlocker: String? {
        branchSwitchBlocker ?? (snapshot?.head == nil ? "先完成第一次提交。" : nil)
    }

    func checkout(_ branch: String) {
        guard branch != snapshot?.branch else { return }
        prepareBranchSwitch(.local(branch))
    }

    func trackBranch(_ remote: RemoteBranch) {
        guard branchSwitchBlocker == nil else { return }
        if snapshot?.branches.contains(where: { $0 == remote.name || $0.hasPrefix(remote.name + "/") || remote.name.hasPrefix($0 + "/") }) == true {
            refPrompt = .trackBranch(remote)
        } else {
            prepareBranchSwitch(.remote(remote, name: remote.name))
        }
    }

    func prepareBranchSwitch(_ target: BranchSwitchTarget) {
        guard !busy, let repository, let state = snapshot, branchSwitchBlocker == nil else { return }
        busy = true
        Task {
            let plan: BranchSwitchPlan
            do { plan = try await repository.prepareBranchSwitch(target, expectedFingerprint: state.fingerprint) }
            catch {
                busy = false
                report(error, title: "检查分支切换失败")
                return
            }
            busy = false
            guard self.repository === repository else { return }
            if plan.blocker == nil { runBranchSwitch(plan) }
            else { branchSwitchPrompt = plan }
        }
    }

    func runBranchSwitch(_ plan: BranchSwitchPlan, stashing: Bool = false) {
        branchSwitchPrompt = nil
        guard let repository, branchSwitchBlocker == nil, !stashing || plan.canStash else { return }
        let branch = plan.target.name
        let title: String
        switch plan.target {
        case .local: title = "切换到 \(branch)"
        case .new, .remote: title = "新建并切换到 \(branch)"
        }
        let message = "切换到 \(branch) 前的暂放 · " + defaultStashMessage
        mutate(stashing ? "先暂放改动再切换分支" : title) { [weak self] in
            var entry: StashEntry?
            if stashing {
                entry = try await repository.stashAll(message: message, expectedFingerprint: plan.fingerprint)
                if let entry { self?.pushUndo("暂放改动（\(entry.message)）", .stash(.pop(object: entry.id))) }
            }
            do {
                let fingerprint = stashing ? try await repository.load().fingerprint : nil
                let step = try await repository.checkout(plan, afterStashing: fingerprint)
                self?.pushUndo(title, step)
                return stashing ? "改动已暂放，已切换到「\(branch)」。" : "当前分支是「\(branch)」。"
            } catch {
                if let entry {
                    throw FolmiFailure(message: error.localizedDescription + "\n\n改动已暂放为「\(entry.message)」，可以在「暂放的改动」里拿回。")
                }
                throw error
            }
        }
    }

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
        guard !busy, let repository, let state = snapshot else { return }
        guard renameBlocker(".gitignore") == nil else {
            errorMessage = "请先保存编辑器里的 .gitignore。"
            return
        }
        Task {
            do {
                let tracked = try await repository.isTracked(path)
                let blocker = tracked && !folder ? try await repository.stopTrackingBlocker(path) : nil
                guard !busy, self.repository === repository else { return }
                if tracked, !folder {
                    refPrompt = .ignoreTracked(path: path, fingerprint: state.fingerprint, blocker: blocker)
                } else {
                    addIgnoreRule(path, folder: folder, tracked: tracked, fingerprint: state.fingerprint)
                }
            } catch { report(error, title: "检查忽略规则失败") }
        }
    }

    func addIgnoreRule(_ path: String, folder: Bool = false, tracked: Bool, fingerprint: String) {
        refPrompt = nil
        guard let repository, renameBlocker(".gitignore") == nil else { return }
        let pattern = GitRepository.ignorePattern(for: path, folder: folder)
        mutateUndoable("忽略 \(path)", capture: { try await repository.captureWorktree([".gitignore"]) }) {
            try await repository.addToGitignore(pattern, expectedFingerprint: fingerprint)
            return tracked
                ? "已把 \(pattern) 加进 .gitignore。Git 仍会显示已经跟踪的文件的改动。"
                : "已把 \(pattern) 加进 .gitignore。"
        }
    }

    func stopTracking(_ path: String, fingerprint: String) {
        refPrompt = nil
        guard let repository, renameBlocker(".gitignore") == nil else { return }
        mutateUndoable("停止跟踪 \(path)") {
            let step = try await repository.stopTracking(path, expectedFingerprint: fingerprint)
            return (step, "已在暂存区记录删除，本机文件仍在。⌥⌘Z 可撤销。")
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

    /// Why a file or folder cannot be renamed or deleted right now, said before the box opens.
    func renameBlocker(_ path: String) -> String? {
        editorWorkspace?.documents.contains { ($0.id == path || $0.id.hasPrefix(path + "/")) && $0.isDirty } == true
            ? "编辑器里还有没保存的改动，先保存" : nil
    }

    /// Editor tabs showing `path` or anything inside it.
    private func openTabs(under path: String) -> [String] {
        editorWorkspace?.documents.map(\.id).filter { $0 == path || $0.hasPrefix(path + "/") } ?? []
    }

    /// 重命名 in the file tree: a new name (with slashes, a new place) beside the file or folder. Open tabs follow it.
    /// ⌥⌘Z puts it back.
    func renameFile(_ path: String, to name: String) {
        guard let repository, let root = repositoryURL else { return }
        if let blocker = renameBlocker(path) { errorMessage = blocker + "再改名。"; return }
        let target: String
        do { target = try GitRepository.newFilePath(name, in: (path as NSString).deletingLastPathComponent) }
        catch { report(error, title: "重命名失败"); return }
        guard target != path else { return }
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isFolder)
        let tabs = openTabs(under: path)
        let title = "重命名 \(path) → \(target)"
        var renamed = false
        let after: () -> Void = { [weak self] in
            guard renamed, !tabs.isEmpty else { return }
            tabs.forEach { try? self?.editorWorkspace?.close(id: $0) }
            // `editPath` waits for the operation to finish, which happens right after `after`.
            Task { tabs.forEach { self?.editPath(target + $0.dropFirst(path.count)) } }
        }
        let done = "已把 \(path) 改名为 \(target)。⌥⌘Z 可撤销。"
        if isFolder.boolValue {
            // A folder can hold more than undo keeps in memory, so its undo moves it back instead of rewriting files.
            mutate(title, operation: { [weak self] in
                let step = try await repository.renameFolder(path, to: target)
                await MainActor.run { self?.pushUndo(title, step) }
                return done
            }, succeeded: { renamed = true }, after: after)
        } else {
            mutateUndoable(title, capture: { try await repository.captureWorktree([path, target]) },
                           succeeded: { renamed = true }, after: after) {
                try await repository.renameFile(path, to: target)
                return done
            }
        }
    }

    /// 删除 in the file tree: the file or folder goes to the Trash (Finder can put it back too). Open tabs close.
    /// ⌥⌘Z puts it back.
    func deleteItem(_ path: String) {
        guard let repository else { return }
        if let blocker = renameBlocker(path) { errorMessage = blocker + "再删除。"; return }
        let tabs = openTabs(under: path)
        let title = "删除 \(path)"
        var deleted = false
        mutate(title, operation: { [weak self] in
            let step = try await repository.trashItem(path)
            await MainActor.run { self?.pushUndo(title, step) }
            return "已把 \(path) 移到废纸篓。⌥⌘Z 可撤销。"
        }, succeeded: { deleted = true }, after: { [weak self] in
            guard deleted else { return }
            tabs.forEach { try? self?.editorWorkspace?.close(id: $0) }
        })
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
            .alert(branchTitle, isPresented: binding {
                if case .createAndSwitch = $0 { return true }; if case .trackBranch = $0 { return true }; return false
            }) {
                TextField("分支名，例如 feature/login", text: $name)
                Button("新建并切换") {
                    let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch model.refPrompt {
                    case .createAndSwitch?: model.prepareBranchSwitch(.new(target))
                    case .trackBranch(let remote)?: model.prepareBranchSwitch(.remote(remote, name: target))
                    default: break
                    }
                    model.refPrompt = nil
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) { model.refPrompt = nil }
            } message: {
                if case .trackBranch(let remote) = model.refPrompt {
                    Text("为「\(remote.id)」指定一个可用的本地分支名。")
                } else {
                    Text("从当前提交新建分支。尚未提交的改动会跟过去。")
                }
            }
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
            .alert("添加忽略规则", isPresented: binding { if case .ignoreTracked = $0 { return true }; return false }) {
                if case .ignoreTracked(let path, let fingerprint, let blocker) = model.refPrompt {
                    Button("停止跟踪（保留本机文件）") { model.stopTracking(path, fingerprint: fingerprint) }
                        .disabled(blocker != nil)
                    Button("只添加忽略规则") { model.addIgnoreRule(path, tracked: true, fingerprint: fingerprint) }
                }
                Button("取消", role: .cancel) { model.refPrompt = nil }
            } message: {
                if case .ignoreTracked(let path, _, let blocker) = model.refPrompt {
                    Text("Git 已在跟踪「\(path)」。停止跟踪会在暂存区记录删除，本机文件保留。⌥⌘Z 可撤销。"
                         + (blocker.map { "\n\n" + $0 } ?? ""))
                }
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
                switch prompt {
                case .renameBranch(let branch)?: name = branch
                case .trackBranch(let remote)?: name = remote.id
                default: name = ""
                }
                message = ""
            }
    }

    private var branchTitle: String {
        if case .trackBranch = model.refPrompt { return "新建本地跟踪分支" }
        return "新建并切换分支"
    }

    private var deleteTitle: String {
        switch model.refPrompt {
        case .deleteBranch(let branch, _)?: return "删除分支「\(branch)」？"
        case .deleteTag(let tag)?: return "删除标签「\(tag)」？"
        default: return ""
        }
    }
}
