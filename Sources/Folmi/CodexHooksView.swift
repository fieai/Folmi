import SwiftUI

/// Codex keeps these hooks in the selected project, and owns the subsequent trust review.
struct CodexHooksSection: View {
    let root: URL?
    @State private var status = HooksInstaller.Status(installed: false, guarded: false)
    @State private var guarded = true
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex 钩子").themedFont(.headline, points: 13)
            Text("记录本项目里 Codex 的文件改动，显示活动并支持整批撤回。一次 apply_patch 修改多个文件时会分别保存改前内容。")
                .themedFont(.callout, points: 12).fixedSize(horizontal: false, vertical: true)
            if let root {
                Text(HooksInstaller.settingsURL(root, agent: .codex).path)
                    .themedFont(.caption.monospaced(), points: 10).textSelection(.enabled)
            }
            Toggle("同时拦截危险的 git 命令（guardrails）", isOn: $guarded)
            Text("写入后，在这个项目中新开 Codex，运行 /hooks 审核并信任工作台钩子。Codex 只会运行已信任的钩子；这里显示的安装状态不代表已获信任。")
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(status.installed ? "配置已写入 · 信任状态由 Codex 管理" : "尚未写入项目配置")
                    .themedFont(.caption, points: 10).foregroundStyle(.secondary)
                Spacer()
                if status.installed {
                    Button("移除 Codex 钩子") { run { try HooksInstaller.uninstall($0, agent: .codex) } }
                }
                Button(status.installed ? "更新 Codex 钩子" : "接入 Codex 钩子") {
                    run { try HooksInstaller.install($0, agent: .codex, guarded: guarded) }
                }.buttonStyle(.folmiProminent).disabled(root == nil)
            }
            if let message { Text(message).themedFont(.caption, points: 10).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .onAppear {
            refresh()
            guarded = status.installed ? status.guarded : true
        }
    }

    private func refresh() { if let root { status = HooksInstaller.status(root, agent: .codex) } }
    private func run(_ action: (URL) throws -> Void) {
        guard let root else { return }
        do { try action(root); refresh(); message = status.installed ? "已写入。请在新开的 Codex 中通过 /hooks 审核信任。" : "已移除工作台的 Codex 钩子，其他配置保留。" }
        catch { message = error.localizedDescription }
    }
}
