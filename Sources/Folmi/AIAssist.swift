import AppKit
import FolmiCore
import SwiftUI

/// The small AI card: one request, streamed, then copy or hand it to Claude in the terminal. Not a chat app: it keeps
/// only the current exchange and closes with Esc.
struct AIAssistState: Equatable {
    enum Mode: String, Equatable {
        case plain, deAI, explain, ask
        var title: String {
            switch self {
            case .plain: return "说人话"
            case .deAI: return "去 AI 腔"
            case .explain: return "解释改动"
            case .ask: return "问 AI"
            }
        }
        var system: String {
            switch self {
            case .plain: return AIPrompts.plain
            case .deAI: return AIPrompts.deAI
            case .explain: return AIPrompts.explainDiff
            case .ask: return AIPrompts.ask
            }
        }
        var use: AIUse { self == .plain || self == .deAI ? .rewrite : .explain }
    }
    struct Turn: Equatable { var question: String; var answer: String }
    var mode: Mode
    /// What the request is about, e.g. "README.md:12-20" or "终端选中内容".
    var source: String
    var input: String
    var output = ""
    var running = false
    var error: String?
    /// Ask mode: earlier questions about the same context, newest last.
    var turns: [Turn] = []
}

extension FolmiModel {
    func assist(_ mode: AIAssistState.Mode, text: String, source: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { NSSound.beep(); return }
        if let finding = SecretScan.findings(in: trimmed).first {
            aiAssist = AIAssistState(mode: mode, source: source, input: trimmed, error: "内容疑似含密钥（\(finding)），没有发给 AI。")
            return
        }
        aiAssist = AIAssistState(mode: mode, source: source, input: String(trimmed.prefix(60_000)))
        if mode != .ask { runAssist(question: nil) }
    }

    /// ⌘L / "问 AI": the open file or the selected diff is the context.
    func openAsk() {
        if content == .editor, let document = editorWorkspace?.selectedDocument {
            aiAssist = AIAssistState(mode: .ask, source: document.path, input: String(document.text.prefix(40_000)))
        } else if let diff = fileDiff {
            aiAssist = AIAssistState(mode: .ask, source: "\(diff.file.path) 的改动", input: String(diff.rawPatch.prefix(40_000)))
        } else {
            aiAssist = AIAssistState(mode: .ask, source: repositoryTitle, input: "")
        }
    }

    func runAssist(question: String?) {
        guard var state = aiAssist else { return }
        assistTask?.cancel()
        let client = AIClient.client(for: state.mode.use, project: repositoryURL?.path, settings: aiSettings)
        guard client.isAvailable else {
            state.error = client.problem
            aiAssist = state; return
        }
        var user = state.mode == .ask ? "上下文（\(state.source)）：\n\(state.input)\n\n" : state.input
        if state.mode == .ask {
            for turn in state.turns { user += "问：\(turn.question)\n答：\(turn.answer)\n\n" }
            user += "问：\(question ?? "")"
            state.turns.append(.init(question: question ?? "", answer: ""))
        }
        state.running = true; state.error = nil; state.output = ""
        aiAssist = state
        let system = state.mode.system
        assistTask = Task { [weak self] in
            do {
                for try await text in client.stream(system: system, user: user, maxTokens: 1_500) {
                    guard let self, !Task.isCancelled else { return }
                    self.aiAssist?.output = text
                    if self.aiAssist?.mode == .ask, let last = self.aiAssist?.turns.indices.last { self.aiAssist?.turns[last].answer = text }
                }
                self?.aiAssist?.running = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.aiAssist?.running = false
                self.aiAssist?.error = error.localizedDescription
            }
        }
    }
    func closeAssist() { assistTask?.cancel(); aiAssist = nil }
    /// An explanation on the review or diff page shows beside the code rather than floating over it.
    var assistBesideReview: Bool { (content == .allChanges || content == .diff) && aiAssist?.mode == .explain }

    /// "交给 Claude": the request and its context go into the terminal (not sent), for the agent to act on.
    func handAssistToClaude() {
        guard let state = aiAssist else { return }
        let text = state.mode == .ask
            ? "关于 \(state.source)：\(state.turns.last?.question ?? "")"
            : "\(state.mode.title)：\(state.source)\n\n\(state.input.prefix(4_000))"
        if !showTerminal || terminalSession == nil { focusPane(.terminal) }
        sendTextToTerminal(text)
        closeAssist()
    }

    func explainHunk(_ hunk: DiffHunk, in diff: FileDiff) {
        let body = hunk.lines.map { line -> String in
            switch line.kind { case .addition: return "+" + line.text; case .deletion: return "-" + line.text; case .context: return " " + line.text; case .meta: return line.text }
        }.joined(separator: "\n")
        assist(.explain, text: "文件：\(diff.file.path)\n\(hunk.header)\n\(body)", source: "\(diff.file.path) \(hunk.header.prefix(40))")
    }

    /// A slash command for the agent in the terminal, pasted without Enter so it can be read first.
    func sendSlashCommand(_ command: String) {
        if !showTerminal || terminalSession == nil { focusPane(.terminal) }
        sendTextToTerminal(command)
    }

    /// AI 快检: the selected diff (or what is staged) read for obvious problems, in the AI card.
    func quickCheckDiff() {
        if let diff = fileDiff, !diff.rawPatch.isEmpty {
            assist(.explain, text: "文件：\(diff.file.path)\n\(diff.rawPatch.prefix(30_000))", source: "\(diff.file.path) 的改动")
        } else { NSSound.beep() }
    }

    /// Asks whether the staged change should be several commits; the answer lands in the AI card.
    func suggestSplit() {
        guard let repository else { return }
        Task { [weak self] in
            guard let staged = try? await repository.stagedPatch(limit: 40_000), !staged.patch.isEmpty else { NSSound.beep(); return }
            await MainActor.run {
                self?.aiAssist = AIAssistState(mode: .explain, source: "暂存区 · 拆分建议", input: "")
                self?.assistSplit(stat: staged.stat, patch: staged.patch)
            }
        }
    }
    private func assistSplit(stat: String, patch: String) {
        guard SecretScan.findings(in: patch).isEmpty else { aiAssist?.error = "暂存内容疑似含密钥，没有发给 AI。"; return }
        let client = AIClient.client(for: .explain, project: repositoryURL?.path, settings: aiSettings)
        guard client.isAvailable else { aiAssist?.error = client.problem; return }
        aiAssist?.running = true
        assistTask?.cancel()
        assistTask = Task { [weak self] in
            do {
                let text = try await client.complete(system: AIPrompts.splitCommits, user: "Stat:\n\(stat)\n\nDiff:\n\(patch)", maxTokens: 800)
                self?.aiAssist?.output = Self.describeSplit(text)
            } catch { self?.aiAssist?.error = error.localizedDescription }
            self?.aiAssist?.running = false
        }
    }
    /// The model's JSON as readable lines; its raw text when it is not JSON.
    nonisolated static func describeSplit(_ text: String) -> String {
        let json = text.drop(while: { $0 != "{" }).reversed().drop(while: { $0 != "}" }).reversed()
        guard let data = String(json).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = object["groups"] as? [[String: Any]] else { return text }
        if groups.count <= 1 { return "不需要拆分：这些改动属于同一件事。" }
        return "建议拆成 \(groups.count) 次提交：\n\n" + groups.enumerated().map { index, group in
            let title = group["title"] as? String ?? "第 \(index + 1) 组"
            let paths = (group["paths"] as? [String] ?? []).map { "  · " + $0 }.joined(separator: "\n")
            return "\(title)\n\(paths)"
        }.joined(separator: "\n\n") + "\n\n按组暂存后分别提交：先在改动列表里取消暂存其他组的文件。"
    }

    /// The selected terminal text, for 说人话 on what the agent printed.
    var terminalSelection: String? { terminalSession?.terminalView.getSelection() }
}

/// A diff page with the AI explanation docked on its right: the code it explains stays readable, and ⏎ / ⌫ keep
/// working while it is written.
private struct AssistBeside: ViewModifier {
    let model: FolmiModel
    @Environment(\.folmiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
            if model.assistBesideReview {
                Divider()
                AIAssistCard(model: model, beside: true).frame(width: 320)
                    .background(Color.theme(theme, \.card))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Motion.reveal, value: model.assistBesideReview)
    }
}

extension View {
    func assistBeside(_ model: FolmiModel) -> some View { modifier(AssistBeside(model: model)) }
}

struct AIAssistCard: View {
    @Bindable var model: FolmiModel
    /// Inside the terminal card's AI tab rather than floating over the window.
    var docked = false
    /// Beside the review page, explaining one hunk: full height, closable, never over the code.
    var beside = false
    @State private var question = ""
    @FocusState private var questionFocused: Bool

    var body: some View {
        let _ = PerfLog.body("AIAssistCard")
        if let state = model.aiAssist {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(ThemeColor(token: .accent))
                    Text(state.mode.title).themedFont(.headline, points: 13)
                    Text(state.source).themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if state.running { ProgressView().controlSize(.small) }
                    if docked {
                        Button("换成当前文件") { model.openAsk() }.controlSize(.small).help("把上下文换成现在打开的文件或改动")
                    } else {
                        Button { model.closeAssist() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.pressable).keyboardShortcut(.cancelAction).help("关闭（Esc）").accessibilityLabel("关闭")
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if state.mode == .ask {
                            ForEach(Array(state.turns.enumerated()), id: \.offset) { _, turn in
                                Text(turn.question).themedFont(.callout.weight(.medium), points: 12)
                                Text(turn.answer.isEmpty ? "…" : turn.answer).themedFont(.callout, points: 12).textSelection(.enabled)
                            }
                            if state.turns.isEmpty {
                                Text("问当前\(state.source.isEmpty ? "项目" : "「\(state.source)」")的问题：解释、总结、找风险。需要改代码时用「交给 agent」。")
                                    .themedFont(.callout, points: 12).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(state.output.isEmpty ? (state.running ? waiting(state) : "") : state.output)
                                .themedFont(.callout, points: 12).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let error = state.error {
                            Label(error, systemImage: "exclamationmark.triangle").themedFont(.caption, points: 10).foregroundStyle(.themed(.modified))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: docked || beside ? .infinity : 320)
                if state.mode == .ask {
                    HStack {
                        TextField("问点什么…（⏎ 发送）", text: $question).themedTextField().focused($questionFocused)
                            .onSubmit { send() }
                        Button("发送", action: send).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || state.running)
                    }
                }
                HStack(spacing: 8) {
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.mode == .ask ? (state.turns.last?.answer ?? "") : state.output, forType: .string)
                    }.disabled(state.output.isEmpty)
                    if state.mode != .ask { Button("再写一次") { model.runAssist(question: nil) }.disabled(state.running) }
                    Spacer()
                    Button("粘贴到终端", action: model.handAssistToClaude)
                        .help("把这个请求粘贴到终端（不回车），让终端里的 agent 动手")
                    Button("交给 agent", action: model.handAssistToAgent).buttonStyle(.folmiProminent)
                        .help("带着这段上下文，在终端卡片的 AI 标签里交给 Claude / Codex")
                }.controlSize(.small)
            }
            .padding(14)
            .frame(width: docked || beside ? nil : 460)
            .frame(maxWidth: docked || beside ? .infinity : nil, maxHeight: docked || beside ? .infinity : nil, alignment: .top)
            .background(docked || beside ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(docked || beside ? 0 : 0.1)))
            .shadow(color: .black.opacity(docked || beside ? 0 : 0.18), radius: 18, y: 6)
            .onAppear { if state.mode == .ask { questionFocused = true } }
        }
    }

    /// What the wait is for, instead of a bare "正在写…".
    private func waiting(_ state: AIAssistState) -> String {
        guard state.mode == .explain else { return "正在写…" }
        return beside ? "正在读这一块改动，写好就显示在这里。左边可以照常看、照常收下。" : "正在读这段改动，写好就显示在这里…"
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        model.runAssist(question: text)
    }
}
