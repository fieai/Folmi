import AppKit
import Foundation
import FolmiCore

extension FolmiModel {
    /// Check before reading a cached snapshot: a cached project must never disguise a missing folder.
    func projectPathIsAvailable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            let path = url.standardizedFileURL.path
            missingProjectPath = projects.contains { $0.rootPath == path } ? path : nil
            report(FolmiError.projectDirectoryUnavailable(path: path,
                message: exists ? "此路径不是文件夹。" : "目录不存在、已被移动或当前无权访问。"), title: "打开项目失败")
            return false
        }
        missingProjectPath = nil
        return true
    }

    /// Git found no repository here or above. A saved project gets the relocate / remove choices; a folder just
    /// picked gets a way to pick another one, instead of Git's exit code.
    func reportNotRepository(_ url: URL) {
        let path = url.standardizedFileURL.path
        if projects.contains(where: { $0.rootPath == path }) { missingProjectPath = path } else { notRepositoryPath = path }
        let message = "「\(url.lastPathComponent)」不是 Git 仓库：这个文件夹和它的上层都没有 .git。\n请选择项目的根目录（含 .git 的文件夹），或其中的子文件夹。"
        errorMessage = message
        record("打开项目失败", message + "\n\(path)", isError: true)
    }
    nonisolated static func isNotRepository(_ error: Error) -> Bool {
        guard case let FolmiError.git(code, message) = error, code == 128 else { return false }
        return message.localizedCaseInsensitiveContains("not a git repository") || message.contains("不是 git 仓库")
    }
    func chooseAnotherRepository() {
        notRepositoryPath = nil; errorMessage = nil
        openRepository()
    }

    var missingProjectName: String {
        projects.first { $0.rootPath == missingProjectPath }?.name ?? "项目"
    }

    func relocateMissingProject() {
        guard !busy, missingProjectPath != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "重新定位\(missingProjectName)"; panel.prompt = "使用此文件夹"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { missingProjectPath = nil; return }
        Task {
            guard let root = await relocateMissingProject(to: url),
                  let project = projects.first(where: { $0.rootPath == root.path }) else { return }
            open(root, environment: project.environment, demo: project.isDemo)
        }
    }

    /// Validate the new Git root before changing any saved settings. Relative tabs, drafts and comments follow it.
    @discardableResult
    func relocateMissingProject(to url: URL) async -> URL? {
        guard !busy, let oldPath = missingProjectPath, let oldProject = savedProject(oldPath) else { return nil }
        guard editors[oldPath]?.hasUnsavedChanges != true else {
            errorMessage = "此项目仍有未保存的编辑，请先恢复原目录并保存，再重新定位。"
            return nil
        }
        busy = true
        defer { busy = false }
        do {
            try savePreferencesNow()
            let candidate = GitRepository(url: url, environment: oldProject.environment, largeRepository: oldProject.largeRepository)
            let state = try await candidate.load()
            let newPath = state.root.path
            guard newPath == oldPath || !projects.contains(where: { $0.rootPath == newPath }) else {
                throw FolmiError.unsupported("所选目录已在项目列表中，请直接切换到该项目，或选择原项目的新位置。")
            }
            let previousProjects = projects, previousPreferences = preferences, previousComments = reviewComments
            do {
                if let index = projects.firstIndex(where: { $0.rootPath == oldPath }) {
                    var relocated = savedProject(oldPath) ?? oldProject
                    relocated.rootPath = newPath
                    relocated.reviewComments = relocated.reviewComments.map { $0.relocated(to: newPath) }
                    projects[index] = relocated
                    // captureProjectState reads these before serializing; replace both copies together.
                    preferences.projects.removeAll { $0.rootPath == oldPath }
                    preferences.projects.append(relocated)
                }
                reviewComments = reviewComments.map { $0.projectPath == oldPath ? $0.relocated(to: newPath) : $0 }
                if preferences.selectedProjectPath == oldPath { preferences.selectedProjectPath = newPath }
                try savePreferencesNow()
            } catch {
                projects = previousProjects; preferences = previousPreferences; reviewComments = previousComments
                saveTask?.cancel(); saveTask = nil; saveDeadline = nil
                throw error
            }
            discardRecoveredProjectCaches(oldPath)
            missingProjectPath = nil; errorMessage = nil
            record("项目已重新定位", "\(oldPath)\n→ \(newPath)")
            return state.root
        } catch {
            report(error, title: "重新定位项目失败")
            return nil
        }
    }

    /// Removes only the saved list entry. Never deletes the repository or its files.
    @discardableResult
    func removeMissingProject() -> Bool {
        guard !busy, let path = missingProjectPath else { return false }
        guard path != repositoryURL?.path, editors[path]?.hasUnsavedChanges != true else {
            errorMessage = "此项目仍在使用或有未保存编辑，请先恢复目录并保存、切换项目，再从列表中移除。"
            return false
        }
        guard forgetProject(path) else { return false }
        missingProjectPath = nil; errorMessage = nil
        return true
    }

    /// Whether 从项目列表移除 can be offered for `path`: the open project needs another to switch to first.
    func canRemoveProject(_ path: String) -> Bool {
        path != repositoryURL?.path || projects.contains { $0.rootPath != path }
    }

    /// 从项目列表移除: the list entry, its saved state and review comments go; the folder and its files stay. The open
    /// project switches to another one first and is removed once that one is open.
    func removeProject(_ path: String) {
        guard !busy, projects.contains(where: { $0.rootPath == path }) else { return }
        guard editors[path]?.hasUnsavedChanges != true else {
            errorMessage = "「\(projects.first { $0.rootPath == path }?.name ?? path)」有未保存的编辑，请先保存或放弃，再从列表移除。"
            return
        }
        if path == repositoryURL?.path {
            guard let next = projects.first(where: { $0.rootPath != path }) else { return }
            removeAfterSwitch = path
            switchProject(next.rootPath)
        } else {
            forgetProject(path)
        }
    }

    /// Called when a project finished opening: drops the project that was waiting for the switch.
    func finishPendingRemoval() {
        guard let path = removeAfterSwitch else { return }
        removeAfterSwitch = nil
        if path != repositoryURL?.path { forgetProject(path) }
    }

    @discardableResult
    func forgetProject(_ path: String) -> Bool {
        let previousProjects = projects, previousPreferences = preferences, previousComments = reviewComments
        do {
            projects.removeAll { $0.rootPath == path }
            preferences.projects.removeAll { $0.rootPath == path }
            reviewComments.removeAll { $0.projectPath == path }
            if preferences.selectedProjectPath == path { preferences.selectedProjectPath = nil }
            try savePreferencesNow()
            discardRecoveredProjectCaches(path)
            editorObservers.removeValue(forKey: path)
            record("已从项目列表移除", path)
            return true
        } catch {
            projects = previousProjects; preferences = previousPreferences; reviewComments = previousComments
            saveTask?.cancel(); saveTask = nil; saveDeadline = nil
            report(error, title: "移除项目失败")
            return false
        }
    }

    private func discardRecoveredProjectCaches(_ path: String) {
        // An inactive project's old cwd and undo history cannot be reused at another filesystem location.
        editors.removeValue(forKey: path)
        terminals.removeValue(forKey: path)?.forEach { $0.stop() }
        selectedTerminals.removeValue(forKey: path)
        terminalTabsCleared.remove(path)
        undoStacks.removeValue(forKey: path); redoStacks.removeValue(forKey: path)
        aiBatchStore.removeValue(forKey: path); aiEventOffsets.removeValue(forKey: path)
    }
}

private extension ReviewComment {
    func relocated(to root: String) -> ReviewComment {
        ReviewComment(id: id, projectPath: root, path: path, area: area, firstLine: firstLine, lastLine: lastLine,
            excerpt: excerpt, body: body, anchor: anchor, anchorStart: anchorStart, outdated: outdated,
            created: created, addressed: addressed)
    }
}
