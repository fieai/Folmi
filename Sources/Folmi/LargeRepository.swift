import SwiftUI

/// 大仓库模式: for a repository whose `git status` is slow, Git's own file system monitor and untracked cache make
/// it fast again. It starts Git's monitor daemon for that repository, so it is offered, never switched on silently.
extension FolmiModel {
    /// A status slower than this, twice in a row, brings up the offer.
    static let slowStatus: TimeInterval = 0.3

    var largeRepositoryOn: Bool { repositoryURL.flatMap { savedProject($0.path) }?.largeRepository ?? false }

    func setLargeRepository(_ on: Bool) {
        guard let root = repositoryURL, let repository else { return }
        updateProject(root.path) { $0.largeRepository = on; if on { $0.largeRepositoryDeclined = false } }
        largeRepositoryOffer = false
        Task {
            await repository.setLargeRepository(on)
            refreshInBackground()
        }
        record(on ? "已打开大仓库模式" : "已关闭大仓库模式",
               on ? "读取状态改用 Git 的文件监视和未跟踪文件缓存（git fsmonitor--daemon 会在后台为这个仓库运行）。"
                  : "读取状态回到普通方式。后台的 Git 文件监视可以用 `git fsmonitor--daemon stop` 停掉。")
    }
    func declineLargeRepository() {
        guard let root = repositoryURL else { return }
        updateProject(root.path) { $0.largeRepositoryDeclined = true }
        largeRepositoryOffer = false
    }

    /// After each status read: two slow ones in a row offer the mode once per project.
    func noteStatusDuration(_ duration: TimeInterval) {
        guard let root = repositoryURL, let project = savedProject(root.path), !project.largeRepository, !project.largeRepositoryDeclined else {
            slowStatusCount = 0; return
        }
        slowStatusCount = duration > Self.slowStatus ? slowStatusCount + 1 : 0
        if slowStatusCount >= 2, !largeRepositoryOffer { largeRepositoryOffer = true; lastSlowStatus = duration }
    }

    private func updateProject(_ path: String, _ change: (inout ProjectPreferences) -> Void) {
        if let index = projects.firstIndex(where: { $0.rootPath == path }) { change(&projects[index]) }
        if let index = preferences.projects.firstIndex(where: { $0.rootPath == path }) { change(&preferences.projects[index]) }
        scheduleSave()
    }
}

struct LargeRepositoryOffer: View {
    let model: FolmiModel
    var body: some View {
        if model.largeRepositoryOffer {
            HStack(spacing: 10) {
                Image(systemName: "speedometer").foregroundStyle(.secondary)
                Text("这个仓库读一次状态要 \(String(format: "%.1f", model.lastSlowStatus)) 秒。打开大仓库模式会快不少。")
                    .themedFont(.callout, points: 12)
                Button("打开") { model.setLargeRepository(true) }.buttonStyle(.folmiProminent)
                Button("不用") { model.declineLargeRepository() }
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .themedCapsule(.regularMaterial)
            .help("用 Git 自带的文件监视（fsmonitor）和未跟踪文件缓存读取状态；会在后台为这个仓库运行一个 Git 进程。以后可以在 ⌘K 里关掉。")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
