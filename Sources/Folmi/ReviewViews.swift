import AppKit
import FolmiCore
import SwiftUI
import UniformTypeIdentifiers

/// Where the commit message stands: being written, written by which model, or why it was not.
struct CommitSuggestionStatus: View {
    let model: FolmiModel
    var body: some View {
        let _ = PerfLog.body("CommitSuggestionStatus")
        switch model.commitSuggestion {
        case .idle: EmptyView()
        case .generating:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("AI 正在写提交说明…") }
                .themedFont(.caption2, points: 10).foregroundStyle(.secondary)
        case .ready(let source):
            Label("已写好 · \(source)", systemImage: "sparkles").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
        case .skipped(let reason):
            Label(reason, systemImage: "hand.raised").themedFont(.caption2, points: 10).foregroundStyle(.themed(.modified)).lineLimit(1).help(reason)
        case .failed(let reason):
            Label("没写成：\(reason)", systemImage: "exclamationmark.triangle").themedFont(.caption2, points: 10).foregroundStyle(.themed(.modified))
                .lineLimit(1).help(reason)
        }
    }
}

/// Endpoint, model and key for the built-in AI features. The key goes to the keychain.
struct AISettingsSheet: View {
    @Bindable var model: FolmiModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var draft: AISettingsDraft
    @State private var saveError: String?
    @State private var loaded = false

    init(model: FolmiModel) {
        self.model = model
        _draft = State(initialValue: AISettingsDraft(settings: model.aiSettings, readKey: { _ in nil }))
    }
    @State private var testResult: String?
    /// Which provider the result belongs to: it shows next to that provider's test button.
    @State private var testTarget: String?
    @State private var testing = false

    var body: some View {
        let _ = PerfLog.body("AISettingsSheet")
        VStack(alignment: .leading, spacing: 12) {
            Text("AI 设置").themedFont(.title3.weight(.semibold), points: 15)
            Text("可以加多个服务商，再按用途选：高频的提交说明用便宜快的，解释改动用强一点的。已登录的 claude / codex 命令行不用填 Key。")
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                providersSection
                if let index = selectedIndex { editor(index) }
                Section("本机命令行") {
                    cliRow(.claudeCLI); cliRow(.codexCLI)
                    if let testTarget, testTarget.hasPrefix("cli."), let testResult {
                        Text(testResult).themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Toggle("没有可用的服务商时用本机命令行", isOn: $draft.settings.useCLIFallback)
                }
                usesSection
                Section("agent 会话（终端卡片的 AI 标签）") {
                    ForEach(AgentKind.allCases) { kind in
                        FormTextField(title: kind.title, text: agentCommandBinding(kind), prompt: kind.defaultCommand)
                    }
                    Text("通过 ACP 适配器启动，用你本机 \(AgentKind.allCases.map(\.title).joined(separator: " / ")) 的登录；默认命令要 Node.js（npx），第一次会下载适配器。")
                        .themedFont(.caption2, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section("这个项目") {
                    if let project = model.repositoryURL?.path {
                        Toggle("只用本机模型（Ollama、LM Studio）", isOn: localOnlyBinding(project))
                    }
                    Toggle("验收时在后台预写提交说明", isOn: $draft.settings.autoCommitMessage)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 320, idealHeight: 460, maxHeight: .infinity)
            if let saveError {
                Text(saveError).themedFont(.caption, points: 11).foregroundStyle(.themed(.removed)).textSelection(.enabled)
            }
            Text("修改在点击保存后生效；测试只使用当前草稿。").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
            HStack {
                Text("发送前会检查密钥、.env 和私钥文件，疑似含密钥的内容不会发出。").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 620)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = AISettingsDraft(settings: model.aiSettings, readKey: AIKeychain.read)
            selected = selected ?? draft.settings.providers.first?.id
        }
    }

    private var selectedIndex: Int? { draft.settings.providers.firstIndex { $0.id == selected } }

    private var providersSection: some View {
        Section {
            if draft.settings.providers.isEmpty {
                Text("还没有服务商。没有的话会用本机命令行。").themedFont(.callout, points: 12).foregroundStyle(.secondary)
            }
            ForEach(draft.settings.providers) { provider in
                Button { selected = provider.id; testResult = nil } label: {
                    HStack {
                        Image(systemName: provider.id == selected ? "largecircle.fill.circle" : "circle").foregroundStyle(.secondary)
                        Text(provider.displayName)
                        Spacer()
                        Text(status(provider)).themedFont(.caption, points: 10).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack {
                Menu("添加服务商") {
                    ForEach(AIProvider.presets) { preset in Button(preset.name) { add(AIProvider.make(preset), key: nil) } }
                }.fixedSize()
                Button("从 llm-commit.env 导入…", action: importEnv)
                Spacer()
            }
        } header: { Text("服务商") }
    }

    private func editor(_ index: Int) -> some View {
        let provider = draft.settings.providers[index]
        return Section(provider.name) {
            FormTextField(title: "名称", text: $draft.settings.providers[index].name)
            Picker("接口格式", selection: $draft.settings.providers[index].kind) {
                Text(AIProvider.Kind.openai.label).tag(AIProvider.Kind.openai)
                Text(AIProvider.Kind.anthropic.label).tag(AIProvider.Kind.anthropic)
            }
            FormTextField(title: "接口地址", text: $draft.settings.providers[index].baseURL, prompt: "https://api.deepseek.com")
            FormTextField(title: "模型", text: $draft.settings.providers[index].model, prompt: "deepseek-chat")
            Toggle("在本机运行（不需要 Key）", isOn: $draft.settings.providers[index].localOnly)
            FormTextField(title: provider.localOnly ? "API Key（可不填）" : "API Key（存在钥匙串）", text: keyBinding(provider.id), secure: true)
            HStack {
                Button(testing ? "测试中…" : "测试", action: { test(provider) }).disabled(testing)
                if testTarget == provider.id, let testResult {
                    Text(testResult).themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("删除", role: .destructive) { remove(provider.id) }
            }
        }
    }

    private func cliRow(_ provider: AIProvider) -> some View {
        HStack {
            Text(provider.name)
            Spacer()
            Text(LocalCLI.path(provider.kind) == nil ? "没有找到" : "可用").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            Button("测试") { test(provider) }.disabled(testing || LocalCLI.path(provider.kind) == nil).controlSize(.small)
        }
    }

    private var usesSection: some View {
        let settings = draft.settings
        let candidates = settings.candidates(cliInstalled: { LocalCLI.path($0) != nil })
        return Section("用途") {
            ForEach(AIUse.allCases) { use in
                VStack(alignment: .leading, spacing: 2) {
                    Picker(use.label, selection: routeBinding(use)) {
                        Text("自动（第一个可用的）").tag("")
                        ForEach(candidates) { Text($0.displayName).tag($0.id) }
                    }
                    Text(resolution(use)).themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func resolution(_ use: AIUse) -> String {
        let result = draft.settings.resolve(use, project: model.repositoryURL?.path, hasKey: { draft.keyForTesting($0) != nil },
                                              cliInstalled: { LocalCLI.path($0) != nil })
        switch result {
        case .ready(let provider): return "现在用：\(provider.displayName)"
        case .missing(let reason): return reason
        }
    }

    private func status(_ provider: AIProvider) -> String {
        if !provider.hasEndpoint { return "未填完" }
        if provider.needsKey && draft.keyForTesting(provider.id) == nil { return "缺 Key" }
        return provider.localOnly ? "本机" : "可用"
    }

    private func keyBinding(_ id: String) -> Binding<String> {
        Binding(get: { draft.keys[id] ?? "" }, set: { draft.setKey($0, for: id) })
    }
    private func routeBinding(_ use: AIUse) -> Binding<String> {
        Binding(get: { draft.settings.routes[use.rawValue] ?? "" },
                set: { draft.settings.routes[use.rawValue] = $0.isEmpty ? nil : $0 })
    }
    private func agentCommandBinding(_ kind: AgentKind) -> Binding<String> {
        Binding(get: { draft.settings.agentCommands[kind.rawValue] ?? "" },
                set: { draft.settings.agentCommands[kind.rawValue] = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }
    private func localOnlyBinding(_ project: String) -> Binding<Bool> {
        Binding(get: { draft.settings.localOnlyProjects.contains(project) }, set: { on in
            draft.settings.localOnlyProjects.removeAll { $0 == project }
            if on { draft.settings.localOnlyProjects.append(project) }
        })
    }

    private func add(_ provider: AIProvider, key: String?) {
        draft.settings.providers.append(provider)
        if let key { draft.setKey(key, for: provider.id) }
        selected = provider.id; testResult = nil
    }
    private func remove(_ id: String) {
        draft.settings.providers.removeAll { $0.id == id }
        draft.settings.routes = draft.settings.routes.filter { $0.value != id }
        draft.keys[id] = nil
        selected = draft.settings.providers.first?.id
    }
    private func save() {
        do {
            let saved = try draft.commit()
            model.applySavedAISettings(saved)
            dismiss()
        } catch { saveError = error.localizedDescription }
    }

    private func importEnv() {
        let panel = NSOpenPanel()
        panel.title = "选择 llm-commit.env"; panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data, .plainText]
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let imported = AISettings.importEnv(text)
        guard let provider = imported.provider else { testResult = "文件里没有找到 COMMIT_LLM_BASE_URL"; testTarget = selected; return }
        add(provider, key: imported.key)
        testTarget = provider.id
        testResult = "已导入 \(provider.displayName)"
    }

    private func test(_ provider: AIProvider) {
        testing = true; testResult = nil; testTarget = provider.id
        let key = draft.keyForTesting(provider.id)
        let client = AIClient.testing(provider, key: key)
        Task {
            let start = ContinuousClock.now
            do {
                let reply = try await client.complete(system: "Reply with the single word: ok", user: "ping", maxTokens: 8)
                let elapsed = ContinuousClock.now - start
                testResult = "可用（\(client.sourceName)，\(elapsed.components.seconds) 秒）：\(reply.prefix(20))"
            } catch { testResult = error.localizedDescription }
            testing = false
        }
    }
}

/// Clean worktree, with separate pending push, pull and stash states.
struct DoneState: View {
    let model: FolmiModel
    /// The all-done title rotates for a little fun. Only scripts the pixel font has: Latin-1 and kana, no hangul.
    static let titles = [
        "今天都收好了", "收工！", "一处不落", "今日事，今日毕", "清清爽爽",
        "All clear.", "Ship it.", "Nothing left. Go touch grass.",
        "C'est fini !", "Voilà, tout est propre.", "¡Listo!", "Feierabend!", "Tutto a posto.", "お疲れさまでした",
    ]
    /// One title per day, picked by the date: it stays put while the view redraws or the app restarts.
    static func title(on date: Date = Date(), calendar: Calendar = .current) -> String {
        titles[(calendar.ordinality(of: .day, in: .era, for: date) ?? 0) % titles.count]
    }
    var body: some View {
        let _ = PerfLog.body("DoneState")
        let summary = model.daySummary
        VStack(spacing: 12) {
            if model.isAllDone {
                if model.theme.style.companion {
                    CompanionMark(state: .success, size: 88)
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 40, weight: .light)).foregroundStyle(.themed(.added))
                }
                Text(Self.title()).themedFont(.title3.weight(.semibold), points: 15)
                if let line = model.daySummaryLine {
                    Text(line + (summary?.hasUpstream == true && (summary?.commitsToday ?? 0) > 0 && model.inReviewCount == 0 ? "，都已推送" : ""))
                        .themedFont(.callout, points: 12).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                if model.inReviewCount > 0 {
                    Text("\(model.inReviewCount) 个提交在评审中，合并后会自动消失").themedFont(.callout, points: 12).foregroundStyle(.secondary)
                }
                StreakLine(days: model.dailyStats.streak())
            } else {
                Image(systemName: (summary?.behind ?? 0) > 0 ? "arrow.down.circle" : "checkmark.circle")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text((summary?.behind ?? 0) > 0 ? "工作区干净" : model.stashedCount > 0 ? "工作区已清空" : "改动都提交了")
                    .themedFont(.title3.weight(.semibold), points: 15)
                if model.stashedCount > 0 {
                    Text("另有 \(model.stashedCount) 批暂放的改动").themedFont(.callout, points: 12).foregroundStyle(.secondary)
                    Button("查看暂放的改动…", action: model.openStashes).buttonStyle(.folmiProminent).disabled(model.busy)
                        .help("每批写着改了什么、拿回会不会冲突，再决定拿回哪一批")
                }
                if let line = model.daySummaryLine {
                    Text(line).themedFont(.callout, points: 12).foregroundStyle(.secondary)
                }
                if let behind = summary?.behind, behind > 0 {
                    Text("有 \(behind) 个提交待拉取").themedFont(.callout, points: 12).foregroundStyle(.secondary)
                    Button("拉取…", action: model.preparePull).buttonStyle(.folmiProminent).disabled(model.busy)
                        .accessibilityIdentifier("clean-workspace-pull")
                    Text("根据最近 fetch 的本地追踪状态；拉取前会重新检查远端。")
                        .themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                }
                if let unpushed = summary?.unpushed, unpushed > 0 {
                    Text("还有 \(unpushed) 个提交没有推送").themedFont(.callout, points: 12).foregroundStyle(.secondary)
                    Button("推送…", action: model.prepareDelivery).buttonStyle(.folmiProminent).disabled(model.busy)
                }
            }
            if let label = model.undoLabel {
                Button("撤销：\(label.prefix(36))", action: model.undoGitOperation).controlSize(.small).disabled(model.busy)
            }
            if let proposal = model.ruleProposals.first {
                RuleProposalCard(model: model, proposal: proposal).padding(.top, 8)
            }
            // Nothing more is suggested once everything is put away: the day can end here. Tidying docs and writing a
            // handoff stay in ⌘K.
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The pre-commit findings above the commit button.
struct CommitCheckView: View {
    let model: FolmiModel
    var body: some View {
        let _ = PerfLog.body("CommitCheckView")
        if model.commitCheckWaiting {
            Label("提交前检查：正在看暂存的内容…", systemImage: "hourglass")
                .themedFont(.caption.weight(.semibold), points: 10).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let check = model.commitCheck, !check.findings.isEmpty || !model.unreviewedStaged.isEmpty {
            let unreviewed = model.unreviewedStaged
            VStack(alignment: .leading, spacing: 4) {
                Label(check.blocking || !unreviewed.isEmpty ? "提交前检查：需要确认" : "提交前检查：提醒",
                      systemImage: check.blocking ? "exclamationmark.octagon" : "exclamationmark.triangle")
                    .themedFont(.caption.weight(.semibold), points: 10).foregroundStyle(check.blocking ? .red : .orange)
                ForEach(unreviewed.keys.sorted().prefix(3), id: \.self) { path in
                    Text("没验收 · \(path) \(unreviewed[path] ?? 0) 处").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                ForEach(check.findings.prefix(5), id: \.self) { finding in
                    Text("\(finding.label) · \(finding.path) \(finding.detail)").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if check.findings.count > 5 { Text("还有 \(check.findings.count - 5) 项…").themedFont(.caption2, points: 10).foregroundStyle(.secondary) }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background((check.blocking ? ThemeColor(token: .removed) : ThemeColor(token: .modified)).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// What a commit right now would leave behind: files with changes only on disk, and files whose staged part
/// goes in while the rest stays. Said next to the commit button so "提交" never reads as "everything".
struct CommitExclusion: Equatable {
    /// Changed on disk, nothing staged (new files included).
    var leftOut: [String] = []
    /// Staged in part; the unstaged rest stays in the working tree.
    var partial: [String] = []
    var isEmpty: Bool { leftOut.isEmpty && partial.isEmpty }

    static func make(_ files: [FileChange]) -> CommitExclusion {
        var result = CommitExclusion()
        for file in files where file.hasWorking && !file.isConflict {
            if file.hasStaged { result.partial.append(file.path) } else { result.leftOut.append(file.path) }
        }
        return result
    }

    /// One line per kind, e.g. "本次不包含：工作区 3 个文件（a.swift、b.md 等）".
    var lines: [String] {
        var lines: [String] = []
        if !leftOut.isEmpty { lines.append("本次不包含：工作区 \(leftOut.count) 个文件（\(Self.names(leftOut))）") }
        if !partial.isEmpty { lines.append("\(partial.count) 个文件只提交已暂存的部分，其余留在工作区（\(Self.names(partial))）") }
        return lines
    }

    private static func names(_ paths: [String]) -> String {
        let shown = paths.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
        return paths.count > 2 ? shown + " 等" : shown
    }
}

/// The commit box's note on what stays out of this commit; hover lists every path.
struct CommitExclusionNote: View {
    let model: FolmiModel
    var body: some View {
        let _ = PerfLog.body("CommitExclusionNote")
        let exclusion = model.commitExclusion
        if model.stagedCount > 0 || model.amendLast, !exclusion.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(exclusion.lines, id: \.self) { line in
                    Text(line).lineLimit(1).truncationMode(.middle)
                }
            }
            .themedFont(.caption2, points: 10)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help((exclusion.leftOut + exclusion.partial).joined(separator: "\n"))
            .accessibilityElement(children: .combine)
        }
    }
}

/// 「连续第 N 天」 under the wrap-up: shown from the second day on, quiet text, no badge or confetti.
private struct StreakLine: View {
    let days: Int
    var body: some View {
        if days >= 2 {
            Label("连续 \(days) 天在这里验收", systemImage: "flame")
                .themedFont(.caption, points: 10)
                .foregroundStyle(.tertiary)
                .help("每天在工作台里验收、撤回过改动就算一天")
        }
    }
}
