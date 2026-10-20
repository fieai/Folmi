import AppKit
import FolmiCore
import SwiftUI

extension FolmiModel {
    func loadWorktrees() async {
        guard let repository, let root = repositoryURL else { return }
        let list = (try? await repository.worktrees()) ?? []
        guard repositoryURL == root, list != worktrees else { return }
        worktrees = list
    }
}

/// The project rail's rows: each project, then the working trees of the same repository under it. Worktrees that
/// were opened before are projects of their own; the open repository's other worktrees show too, faint, one click
/// from opening.
enum RailEntry: Identifiable {
    case project(ProjectPreferences)
    case worktreeProject(ProjectPreferences, branch: String?)
    case unopened(WorktreeInfo)

    var id: String {
        switch self {
        case .project(let project), .worktreeProject(let project, _): return project.rootPath
        case .unopened(let worktree): return "worktree:" + worktree.path
        }
    }

    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    @MainActor static func entries(projects: [ProjectPreferences], current: String?, worktrees: [WorktreeInfo]) -> [RailEntry] {
        let listed = Set(projects.map { canonical($0.rootPath) })
        var mains: [String: String] = [:]
        for project in projects {
            if let main = WorktreeInfo.mainRoot(of: project.rootPath).map(canonical), listed.contains(main) {
                mains[project.rootPath] = main
            }
        }
        let currentKey = current.map(canonical)
        let currentGroup = current.flatMap { mains[$0] } ?? currentKey
        var result: [RailEntry] = []
        for project in projects where mains[project.rootPath] == nil {
            result.append(.project(project))
            let key = canonical(project.rootPath)
            for child in projects where mains[child.rootPath] == key {
                result.append(.worktreeProject(child, branch: WelcomeRecents.branch(at: child.rootPath)))
            }
            if key == currentGroup {
                for worktree in worktrees where !listed.contains(canonical(worktree.path)) {
                    result.append(.unopened(worktree))
                }
            }
        }
        return result
    }
}
