import SwiftUI

/// "● Claude 正在修改 3 个文件…" / "✓ 改完了 · 查看" above the cards: background work made visible.
struct ActivityCapsuleView: View {
    let model: FolmiModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let _ = PerfLog.body("ActivityCapsuleView")
        if let capsule = model.capsule {
            HStack(spacing: 8) {
                switch capsule {
                case let .working(files, prompt):
                    Circle().fill(ThemeColor(token: .modified)).frame(width: 7, height: 7)
                        .opacity(pulse ? 0.35 : 1)
                        .animation(reduceMotion ? nil : Motion.pulse, value: pulse)
                        .onAppear { pulse = true }
                    Text(model.capsuleAgentTitle + " 正在修改" + (files > 0 ? " \(files) 个文件" : "") + "…").themedFont(.caption.weight(.medium), points: 10)
                    if let prompt { Text(prompt).themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 220) }
                case let .finished(files, prompt, batch):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.themed(.added)).font(.caption)
                    Text("\(model.capsuleAgentTitle) 改完了 · \(files) 个文件").themedFont(.caption.weight(.medium), points: 10)
                    if let prompt { Text(prompt).themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 200) }
                    Button("查看") { model.dismissCapsule(); model.showContent(.allChanges) }
                        .buttonStyle(.borderless).themedFont(.caption.weight(.semibold), points: 10)
                    Button("只看这一轮") { model.dismissCapsule(); model.showTurn(batch) }.buttonStyle(.borderless).themedFont(.caption, points: 10)
                        .help("在全部改动里只看这一轮改过的文件，收下、丢弃照常")
                    if model.aiBatches.first(where: { $0.id == batch })?.canUndo == true {
                        Button("撤回") { model.undoAIBatch(batch) }.buttonStyle(.borderless).themedFont(.caption, points: 10)
                            .help("把这一批改动前的文件内容放回去（⌥⌘Z 可以再恢复）")
                    }
                    Button { model.dismissCapsule() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("收起提示")
                case let .external(files, _):
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(ThemeColor(token: .accent)).font(.caption)
                    Text("有 \(files) 个文件刚被改动").themedFont(.caption.weight(.medium), points: 10)
                    Button("查看") { model.dismissCapsule(); model.showContent(.allChanges) }
                        .buttonStyle(.borderless).themedFont(.caption.weight(.semibold), points: 10)
                    Button { model.dismissCapsule() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("收起提示")
                        .help("接入 Claude Code 后，这里会显示 Claude 正在改什么，并能整批撤回")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .themedCapsule(.regularMaterial, stroke: true)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Connects Claude Code to Folmi for one project.
struct HooksSetupSheet: View {
    @Bindable var model: FolmiModel
    @Environment(\.dismiss) private var dismiss
    @State private var status = HooksInstaller.Status(installed: false, guarded: false)
    @State private var guarded = true
    @State private var message: String?

    var body: some View {
        let _ = PerfLog.body("HooksSetupSheet")
        VStack(alignment: .leading, spacing: 12) {
            Text("接入 agent").themedFont(.title3.weight(.semibold), points: 15)
            Text("Claude Code 钩子").themedFont(.headline, points: 13)
            Text("在本项目的 .claude/settings.local.json 里加几个 hook（不会提交进仓库）。装上以后：")
                .themedFont(.callout, points: 12).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("Claude 改文件时，顶部出现「正在修改 / 改完了」", systemImage: "capsule")
                Label("每一轮改动可以整批撤回（Claude 用 Edit / Write 改的文件）", systemImage: "arrow.uturn.backward")
                Label("可选：拦截 git push、reset --hard、clean -f、branch -D、checkout . 等危险命令", systemImage: "hand.raised")
            }.themedFont(.callout, points: 12).foregroundStyle(.secondary)
            Toggle("同时拦截危险的 git 命令（guardrails）", isOn: $guarded)
            if let message { Text(message).themedFont(.caption, points: 10).foregroundStyle(.secondary) }
            HStack {
                Text(status.installed ? (status.guarded ? "已接入（含拦截）" : "已接入") : "尚未接入").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                Spacer()
                if status.installed { Button("移除") { run { try HooksInstaller.uninstall($0) } } }
                Button(status.installed ? "重新安装" : "接入") { run { try HooksInstaller.install($0, guarded: guarded) } }
                    .buttonStyle(.folmiProminent)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("新开的 Claude 会话才会加载 hook。").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            CodexHooksSection(root: model.repositoryURL)
            Divider().padding(.vertical, 4)
            MCPClientsSection()
        }
        .padding(20).frame(width: 560)
        .onAppear { refresh(); guarded = status.installed ? status.guarded : true }
    }
    private func refresh() { if let root = model.repositoryURL { status = HooksInstaller.status(root) } }
    private func run(_ action: (URL) throws -> Void) {
        guard let root = model.repositoryURL else { return }
        do { try action(root); refresh(); message = "已写入 \(HooksInstaller.settingsURL(root).path)" }
        catch { message = error.localizedDescription }
    }
}

/// Every unchecked `[ ]` in the project's Markdown, by file.
struct TasksSheet: View {
    let model: FolmiModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var completionNotice: String?
    @State private var completionError: String?
    @State private var taskRevision = 0

    var body: some View {
        let _ = PerfLog.body("TasksSheet")
        let _ = taskRevision
        let tasks = model.currentMarkdownTasks.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
        let groups = Dictionary(grouping: tasks, by: \.path).sorted { $0.key < $1.key }
        VStack(spacing: 0) {
            HStack {
                Text("全项目待办").themedFont(.headline, points: 13)
                Text("\(tasks.count) 项未完成").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                Spacer()
                TextField("筛选…", text: $query).themedTextField().frame(width: 200)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            if let completionNotice {
                Label(completionNotice, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    .themedFont(.caption, points: 11).padding(.horizontal, 14).padding(.bottom, 10)
            }
            Divider()
            if tasks.isEmpty {
                ContentUnavailableView(model.markdownIndex == nil ? "正在读取 Markdown…" : "没有未完成的待办", systemImage: "checklist.checked")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.key) { path, items in
                        Section {
                            ForEach(items) { task in
                                HStack(spacing: 8) {
                                    Button { complete(task) } label: {
                                        Image(systemName: "square").foregroundStyle(.secondary)
                                            .frame(width: 24, height: 28).contentShape(Rectangle())
                                    }.buttonStyle(.pressable)
                                        .disabled(model.busy)
                                        .accessibilityLabel("完成待办：\(task.text)")
                                        .help("完成待办；文件已有未保存改动时，勾选会保留在草稿中。")
                                    Button {
                                        dismiss()
                                        model.pickPaletteItem(PaletteItem(id: "line:" + task.id, kind: .task, title: task.text, subtitle: path,
                                                                          action: .openLine(path, task.line)))
                                    } label: {
                                        HStack {
                                            Text(task.text).lineLimit(2)
                                            Spacer()
                                            Text("第 \(task.line + 1) 行").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.pressable)
                                        .accessibilityLabel("打开待办：\(task.text)，第 \(task.line + 1) 行")
                                }
                            }
                        } header: {
                            let info = model.currentMarkdownTaskCount(for: path)
                            HStack { Text(path).themedFont(.caption.monospaced(), points: 10); Spacer(); if let info { Text("\(info.done)/\(info.total)").themedFont(.caption2, points: 10) } }
                        }
                    }
                }.listStyle(.inset)
            }
        }
        .frame(width: 720, height: 560)
        .alert("待办未能保存", isPresented: Binding(get: { completionError != nil }, set: { if !$0 { completionError = nil } })) {
            Button("好") { completionError = nil }
        } message: { Text(completionError ?? "") }
    }

    private func complete(_ task: MarkdownIndex.Entry) {
        guard let workspace = model.editorWorkspace else { return }
        do {
            let saved = try workspace.completeIndexedTask(task)
            completionNotice = saved ? "已完成并保存到 \(task.path)" : "已勾选，保留在 \(task.path) 的未保存草稿中"
            taskRevision &+= 1
            model.scheduleMarkdownIndex()
            model.scheduleSave()
        } catch {
            completionError = error.localizedDescription
            taskRevision &+= 1
        }
    }
}
