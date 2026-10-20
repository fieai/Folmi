import SwiftUI
import AppKit
import FolmiCore

/// 推送到远端: send what is already committed out — push a branch, open a Gerrit review, or run the team's own
/// release script. The command is shown first (预览命令 locks the commit), then run.
struct DeliverySheet: View {
    @Bindable var model: FolmiModel
    @Environment(\.dismiss) private var dismiss

    private var explanation: String {
        let remote = model.deliveryRemote.isEmpty ? "远程" : model.deliveryRemote
        let branch = model.deliveryBranch.isEmpty ? "分支" : model.deliveryBranch
        switch model.deliveryKind {
        case .push: return "执行 git push \(remote) <当前提交>:refs/heads/\(branch)，把当前提交推到这个分支。"
        case .gerrit: return "执行 git push \(remote) <当前提交>:refs/for/\(branch)，在 Gerrit 上创建或更新评审。"
        case .script: return "运行你指定的脚本（比如团队的发布脚本），参数原样传入，不经过 shell。"
        }
    }
    private var runTitle: String {
        switch model.deliveryKind { case .push: return "推送"; case .gerrit: return "提交评审"; case .script: return "运行脚本" }
    }

    var body: some View {
        let _ = PerfLog.body("DeliverySheet")
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("推送到远端").themedFont(.title3.weight(.semibold), points: 15)
                    Text("把\(model.repositoryTitle)里已经提交的改动送出去。先预览要执行的命令，确认后再运行；本地提交不会因为推送失败而丢失。")
                        .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 6) {
                ThemedSegmented(options: DeliveryKind.allCases.map { ($0, $0.title) }, selection: $model.deliveryKind, fillsWidth: true)
                Text(explanation).themedFont(.caption, points: 10).foregroundStyle(.secondary)
            }
            .disabled(model.busy)

            if model.deliveryKind == .script {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("脚本的完整路径", text: $model.scriptPath).themedTextField()
                        Button("选择…", action: model.chooseScript)
                    }
                    Text("参数（每行一个）").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                    TextEditor(text: $model.scriptArguments)
                        .themedFont(.system(size: 12, design: .monospaced), points: 12)
                        .frame(height: 68)
                        .padding(4)
                        .themedEditorFrame()
                }
                .disabled(model.busy)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("远程").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                        Picker("远程", selection: $model.deliveryRemote) {
                            Text("选择远程").tag("")
                            ForEach(model.snapshot?.remotes ?? [], id: \.self) { remote in Text(remote).tag(remote) }
                        }
                        .labelsHidden().frame(width: 170)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.deliveryKind == .gerrit ? "评审的目标分支" : "推到哪个分支").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                        TextField("例如 main", text: $model.deliveryBranch).themedTextField()
                    }
                }
                .disabled(model.busy)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("将要执行的命令", systemImage: "terminal").themedFont(.caption.weight(.medium), points: 10)
                // Where it goes first, as fixed rows, then the exact command wrapped from its start: both are
                // readable without scrolling sideways, and nothing opens scrolled to the middle.
                if model.deliveryPlan == nil {
                    Text("点「预览命令」：锁定当前提交、解析推送地址，并在这里列出命令。这一步什么都不会执行。")
                        .themedFont(.system(size: 12), points: 12).foregroundStyle(ThemeColor(token: .secondaryText))
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(model.deliverySummary, id: \.label) { row in
                            GridRow {
                                Text(row.label).themedFont(.caption, points: 10).foregroundStyle(.secondary)
                                Text(row.value).themedFont(.system(size: 12, design: .monospaced), points: 12)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    Text(model.deliveryCommandsText)
                        .themedFont(.system(size: 12, design: .monospaced), points: 12)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                    .themedBackground(ThemeColor(token: .card), .control)
                    Text("只执行这一份计划。评审、CI、合并与部署需分别确认。").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .themedBackground(ThemeColor(token: .hover), .control)

            if model.deliveryKind == .gerrit {
                Text("推送成功只表示 Git 已接收；评审、CI 和合并要在 Gerrit 上确认。").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            }

            if let entry = model.currentActivity.first {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: entry.isError ? "exclamationmark.circle" : "clock")
                        Text(entry.title).fontWeight(.medium)
                        Spacer()
                        Text(entry.date, style: .time).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(entry.details.isEmpty ? "操作记录已保存。" : entry.details)
                            .themedFont(.system(size: 11, design: .monospaced), points: 11)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
                .themedFont(.caption, points: 10)
                .foregroundStyle(entry.isError ? ThemeColor(token: .modified) : ThemeColor(token: .secondaryText))
            }

            DisclosureGroup("常用配置（可选）") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("配置", selection: Binding(get: { model.selectedProfileID }, set: { model.activateProfile($0) })) {
                            Text("不使用").tag(nil as UUID?)
                            ForEach(model.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                        }.labelsHidden().frame(width: 200)
                        TextField("配置名称", text: $model.profileName).themedTextField()
                        Button("保存", action: model.saveDeliveryProfile)
                        Button("另存") { model.activateProfile(nil) }.help("保留上面的设置，另存为新配置")
                        Button(action: model.deleteDeliveryProfile) { Image(systemName: "trash") }.disabled(model.selectedProfileID == nil)
                    }
                    Text("把远程、分支或脚本存起来，下次直接选。只保存在本机的 Folmi 里，每个项目各自一份。")
                        .themedFont(.caption, points: 10).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .themedFont(.caption, points: 10).disabled(model.busy)

            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("预览命令", action: model.preflightDelivery).disabled(model.busy)
                    .help("锁定当前提交并列出命令，不执行")
                Button(runTitle, action: model.runDelivery)
                    .buttonStyle(.folmiProminent)
                    .disabled(!model.canDeliver || model.busy)
                    .help(model.canDeliver ? "执行上面列出的命令" : "先点「预览命令」")
            }
        }
        .padding(22)
        .frame(width: 650)
    }
}

struct ActivitySheet: View {
    @Bindable var model: FolmiModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = PerfLog.body("ActivitySheet")
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("操作记录").themedFont(.title3.weight(.semibold), points: 15)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("本次会话的命令、结果和错误输出。")
                .themedFont(.caption, points: 10)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.activity.isEmpty {
                        Text("还没有操作记录。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 150)
                    }
                    ForEach(model.currentActivity) { entry in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Image(systemName: entry.isError ? "exclamationmark.circle" : "checkmark.circle")
                                    .foregroundStyle(entry.isError ? ThemeColor(token: .modified) : ThemeColor(token: .secondaryText))
                                Text(entry.title).themedFont(.body.weight(.medium), points: 13)
                                Spacer()
                                Text(entry.date, style: .time)
                                    .themedFont(.caption, points: 10)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.details)
                                .themedFont(.system(size: 11, design: .monospaced), points: 11)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
    }
}
