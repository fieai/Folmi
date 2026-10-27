import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// "越用越顺手": what the user keeps turning down becomes a proposed rule for the agent. Nothing is learned silently:
/// a proposal only turns into text in CLAUDE.md / AGENTS.md when the user says so, and every rule stays visible and
/// removable in 记住了什么.
struct RuleProposal: Identifiable, Equatable {
    /// Stable per pattern, so a declined one stays declined.
    let id: String
    /// Why it is proposed, for the user: "最近 3 次都丢弃了 lockfile 的改动".
    let reason: String
    /// The line that would go into the rules section.
    var rule: String
    /// Comment groups: the rule is worth rewording by a model before it is written.
    let fromComments: Bool
    /// The notes behind a comment group, "path：text", for the model that rewords it.
    var examples: [String] = []
}

/// A review note as written, kept for spotting the same request twice (notes themselves go away when sent).
struct NoteRecord: Codable, Equatable {
    enum Kind: String, Codable { case comment, reject }
    var t: Double
    var path: String
    var body: String
    /// A review note, or the reason given for a rejection (decision-reasons.jsonl, read back as notes).
    var kind: Kind = .comment

    init(t: Double, path: String, body: String, kind: Kind = .comment) { self.t = t; self.path = path; self.body = body; self.kind = kind }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        t = try values.decode(Double.self, forKey: .t); path = try values.decode(String.self, forKey: .path)
        body = try values.decode(String.self, forKey: .body); kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .comment
    }
}

/// The rejection the review page offers to explain, until the next one or until the reason is written.
struct RecentReject: Equatable {
    let t: Double
    let path: String
}

/// Per project: which proposals were declined (and when) or written.
struct LearningState: Codable, Equatable {
    var declined: [String: Double] = [:]
    var written: [String] = []
}

enum Learning {
    static let rejectThreshold = 3
    static let commentThreshold = 2
    static let window: TimeInterval = 30 * 86_400
    static let cooldown: TimeInterval = 30 * 86_400

    static func noteLog(gitDir: URL) -> URL { AIEventStore.directory(gitDir: gitDir).appendingPathComponent("note-log.jsonl") }
    static func stateFile(gitDir: URL) -> URL { AIEventStore.directory(gitDir: gitDir).appendingPathComponent("learning.json") }

    static let lockfiles: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "package.resolved", "cargo.lock",
                                         "gemfile.lock", "poetry.lock", "pipfile.lock", "go.sum", "composer.lock", "podfile.lock", "uv.lock"]
    static func isLockfile(_ path: String) -> Bool { lockfiles.contains((path as NSString).lastPathComponent.lowercased()) }

    /// Comment markers by file type. Prose and unknown types have none: a Markdown heading or list item starts with
    /// `#` or `*`, and turning those down says nothing about comments.
    static func commentPrefixes(for path: String) -> [String] {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        let slash = ["//", "/*", "*", "*/"], hash = ["#"], dash = ["--"], markup = ["<!--", "-->"]
        if ["makefile", "dockerfile", "gemfile", "podfile", "rakefile", "brewfile", "justfile"].contains(name) { return hash }
        switch ext {
        case "swift", "c", "h", "m", "mm", "cc", "cpp", "hpp", "cs", "java", "kt", "kts", "scala", "go", "rs", "dart", "js", "jsx",
             "mjs", "cjs", "ts", "tsx", "php", "groovy", "gradle", "proto", "zig", "json5", "jsonc":
            return slash
        case "css", "scss", "less": return ["/*", "*", "*/", "//"]
        case "py", "pyi": return hash + ["\"\"\"", "'''"]
        case "rb", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml", "r", "pl", "pm", "conf", "cfg", "tf", "nix", "ps1", "cmake",
             "mk", "env", "properties":
            return hash
        case "ini": return hash + [";"]
        case "sql", "lua", "hs", "elm", "ada": return dash
        case "lisp", "el", "clj", "cljs", "scm", "asm", "s": return [";"]
        case "html", "htm", "xml", "svg", "plist", "xib", "storyboard": return markup
        case "vue", "svelte", "astro": return markup + slash
        default: return []
        }
    }

    /// Every changed line is blank or a comment in the file's own syntax.
    static func isCommentOnly(_ lines: [String], path: String) -> Bool {
        let prefixes = commentPrefixes(for: path)
        guard !prefixes.isEmpty else { return false }
        let changed = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return !changed.isEmpty && changed.allSatisfy { line in prefixes.contains { line.hasPrefix($0) } }
    }

    /// The patterns worth proposing now, newest evidence first; declined ones wait out their cooldown.
    /// The rule that has the agent use Folmi's call tools; agents leave MCP tools alone unless told to.
    static let callToolsRule = "改 JS、TS、Python 函数前，先用 Folmi MCP 的 callers 看谁在调用它；改完结束前运行 change_impact，把它列出的旧名字调用和参数对不上的调用改好。"

    /// `callTools`: Folmi's MCP is connected and the changes touch code the call map reads.
    static func proposals(decisions: [ReviewDecision], notes: [NoteRecord], state: LearningState, existingRules: [String],
                          callTools: Bool = false, now: Date = Date()) -> [RuleProposal] {
        let since = now.timeIntervalSince1970 - window
        let recent = decisions.filter { $0.t >= since }
        var found: [RuleProposal] = []

        // The same file (or any lockfile) turned down again and again, and not accepted more often than that.
        var byKey: [String: (rejects: Int, accepts: Int, path: String)] = [:]
        for decision in recent {
            let key = isLockfile(decision.path) ? "lockfiles" : "path:" + decision.path
            var entry = byKey[key] ?? (0, 0, decision.path)
            if decision.action == .reject { entry.rejects += 1 } else { entry.accepts += 1 }
            byKey[key] = entry
        }
        for (key, entry) in byKey.sorted(by: { $0.key < $1.key }) where entry.rejects >= rejectThreshold && entry.rejects > entry.accepts {
            if key == "lockfiles" {
                found.append(RuleProposal(id: key, reason: "最近 \(entry.rejects) 次都丢弃了依赖锁文件的改动",
                                          rule: "除非任务明确要求，不要修改依赖锁文件（package-lock.json、yarn.lock、Package.resolved 等）。", fromComments: false))
            } else {
                found.append(RuleProposal(id: key, reason: "最近 \(entry.rejects) 次都丢弃了 \(entry.path) 的改动",
                                          rule: "除非任务明确要求，不要修改 \(entry.path)。", fromComments: false))
            }
        }

        // Changes that only add or edit comments, turned down.
        let commentRejects = recent.filter { $0.action == .reject && $0.commentOnly }.count
        if commentRejects >= rejectThreshold {
            found.append(RuleProposal(id: "comments", reason: "最近 \(commentRejects) 次丢弃的改动都只是注释",
                                      rule: "不要只为了加注释而改代码；除非任务要求，不新增解释性注释。", fromComments: false))
        }

        // The same request written twice or more, about at least two different files: the same note on one spot is
        // about that spot, not a habit worth a rule.
        let recentNotes = notes.filter { $0.t >= since }
        var used = Set<Int>()
        for (index, note) in recentNotes.enumerated().reversed() where !used.contains(index) {
            let similar = recentNotes.indices.filter { $0 != index && !used.contains($0) && similarity(note.body, recentNotes[$0].body) >= 0.5 }
            let group = [note] + similar.map { recentNotes[$0] }
            guard group.count >= commentThreshold, Set(group.map(\.path)).count >= 2 else { continue }
            used.insert(index); similar.forEach { used.insert($0) }
            let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let kinds = Set(group.map(\.kind))
            let what = kinds == [.reject] ? "丢弃原因" : kinds == [.comment] ? "评论" : "评论和丢弃原因"
            found.append(RuleProposal(id: "note:" + stableHash(body),
                                      reason: "你在 \(Set(group.map(\.path)).count) 个文件里写过 \(group.count) 次类似的\(what)：「\(body.prefix(40))」",
                                      rule: body.replacingOccurrences(of: "\n", with: " "), fromComments: true,
                                      examples: group.map { "\($0.path)：\($0.body.replacingOccurrences(of: "\n", with: " "))" }))
        }

        if callTools {
            found.append(RuleProposal(id: "mcp-call-tools", reason: "已接入 Folmi MCP，但不写明的话，Claude / Codex 不会主动用它查调用",
                                      rule: callToolsRule, fromComments: false))
        }

        return found.filter { proposal in
            if state.written.contains(proposal.id) { return false }
            if let declined = state.declined[proposal.id], now.timeIntervalSince1970 - declined < cooldown { return false }
            return !existingRules.contains { similarity($0, proposal.rule) >= 0.8 }
        }
    }

    /// Character-bigram overlap (Jaccard): works for Chinese and English without a tokenizer.
    static func similarity(_ a: String, _ b: String) -> Double {
        func grams(_ text: String) -> Set<String> {
            let chars = Array(text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
            guard chars.count > 1 else { return Set(chars.map(String.init)) }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
        }
        let x = grams(a), y = grams(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}

/// The marked rules section in CLAUDE.md / AGENTS.md. Only the text between the markers is ever changed.
enum RulesFile {
    static let start = "<!-- folmi:rules -->"
    static let end = "<!-- /folmi:rules -->"
    static let heading = "## 验收时记下的要求"

    struct WritePreview {
        let rule: String
        let changes: [Change]
    }

    struct Change: Identifiable {
        let url: URL
        let before: Data?
        let after: Data
        let diff: String
        var id: String { url.path }
        var hasChanges: Bool { before.map { $0 != after } ?? !after.isEmpty }
    }

    enum WriteError: LocalizedError {
        case unreadable(String), changed
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "无法以 UTF-8 读取 \(name)，没有写入规则。"
            case .changed: return "规则文件已变化，请检查更新后的预览，再点一次写入。"
            }
        }
    }

    static func normalizedRule(_ rule: String) -> String {
        rule.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func contents(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    /// Capture both the exact bytes to display and the bytes to write. A read failure must never look like an empty file.
    static func preview(_ rule: String, root: URL) throws -> WritePreview {
        let rule = normalizedRule(rule)
        let changes = try targets(root: root).map { url in
            let before = try contents(url)
            let current: String
            if let before {
                guard let decoded = String(data: before, encoding: .utf8) else { throw WriteError.unreadable(url.lastPathComponent) }
                current = decoded
            } else {
                current = ""
            }
            let next = rule.isEmpty ? current : adding(rule, to: current)
            return Change(url: url, before: before, after: Data(next.utf8),
                          diff: unifiedDiff(before: current, after: next, path: url.lastPathComponent, isNew: before == nil))
        }
        return WritePreview(rule: rule, changes: changes)
    }

    /// Check every file before writing any of them, so edits made while the sheet was open are never overwritten.
    static func write(_ preview: WritePreview, root: URL) throws {
        guard targets(root: root) == preview.changes.map(\.url) else { throw WriteError.changed }
        for change in preview.changes {
            guard try contents(change.url) == change.before else { throw WriteError.changed }
        }
        for change in preview.changes where change.hasChanges { try change.after.write(to: change.url, options: .atomic) }
    }

    /// One contextual hunk covers the rules section, including a missing final newline when relevant.
    static func unifiedDiff(before: String, after: String, path: String, isNew: Bool = false) -> String {
        guard Data(before.utf8) != Data(after.utf8) else { return "" }
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var result = text.components(separatedBy: "\n")
            if text.hasSuffix("\n") { result.removeLast() }
            return result.enumerated().map { index, line in line + (index < result.count - 1 || text.hasSuffix("\n") ? "\n" : "") }
        }
        let old = lines(before), new = lines(after)
        var prefix = 0, suffix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let contextBefore = min(3, prefix), contextAfter = min(3, suffix)
        let begin = prefix - contextBefore
        let oldEnd = old.count - suffix + contextAfter, newEnd = new.count - suffix + contextAfter
        let oldCount = oldEnd - begin, newCount = newEnd - begin
        var result = "--- \(isNew ? "/dev/null" : "a/" + path)\n+++ b/\(path)\n"
        result += "@@ -\(oldCount == 0 ? begin : begin + 1),\(oldCount) +\(newCount == 0 ? begin : begin + 1),\(newCount) @@\n"
        func append(_ line: String, _ marker: String) {
            result += marker + line
            if !line.hasSuffix("\n") { result += "\n\\ No newline at end of file\n" }
        }
        for line in old[begin..<prefix] { append(line, " ") }
        for line in old[prefix..<(old.count - suffix)] { append(line, "-") }
        for line in new[prefix..<(new.count - suffix)] { append(line, "+") }
        for line in old[(old.count - suffix)..<oldEnd] { append(line, " ") }
        return result
    }

    /// CLAUDE.md always; AGENTS.md too when the project has one (Codex reads it).
    static func targets(root: URL) -> [URL] {
        let agents = root.appendingPathComponent("AGENTS.md")
        return [root.appendingPathComponent("CLAUDE.md")] + (FileManager.default.fileExists(atPath: agents.path) ? [agents] : [])
    }

    static func rules(in text: String) -> [String] {
        var seen = Set<String>()
        return blocks(in: text).flatMap { text[$0.section].components(separatedBy: "\n") }.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return nil }
            let rule = String(trimmed.dropFirst(2))
            return seen.insert(rule).inserted ? rule : nil
        }
    }

    /// The text with `rules` as the whole section: added at the end when there was none, removed when empty.
    static func replacing(rules: [String], in text: String) -> String {
        let body = rules.isEmpty ? "" : "\(start)\n\(heading)\n\n" + rules.map { "- " + $0 }.joined(separator: "\n") + "\n\(end)"
        let existing = blocks(in: text)
        if !existing.isEmpty {
            var next = text
            for (index, block) in existing.enumerated().reversed() {
                next.replaceSubrange(block.whole, with: index == 0 ? body : "")
            }
            if body.isEmpty { next = next.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
            return next
        }
        guard !body.isEmpty else { return text }
        let separator = text.isEmpty ? "" : text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
        return text + separator + body + "\n"
    }
    static func adding(_ rule: String, to text: String) -> String {
        let current = rules(in: text)
        if current.contains(rule) { return text }
        return replacing(rules: current + [rule], in: text)
    }
    static func removing(_ rule: String, from text: String) -> String { replacing(rules: rules(in: text).filter { $0 != rule }, in: text) }

    /// Every marked section; the next write consolidates them into one.
    private static func blocks(in text: String) -> [(section: Range<String.Index>, whole: Range<String.Index>)] {
        var result: [(section: Range<String.Index>, whole: Range<String.Index>)] = []
        var cursor = text.startIndex
        while let open = text.range(of: start, range: cursor..<text.endIndex),
              let close = text.range(of: end, range: open.upperBound..<text.endIndex) {
            result.append((open.upperBound..<close.lowerBound, open.lowerBound..<close.upperBound))
            cursor = close.upperBound
        }
        return result
    }
}

extension FolmiModel {
    /// One accept or reject that went through, for the decision log (and the agent's `recent_decisions`).
    func recordDecision(_ action: ReviewDecision.Action, scope: ReviewDecision.Scope, path: String, lines: [DiffLine]) {
        guard let gitDir = aiGitDir else { return }
        let changed = lines.filter { $0.kind == .addition || $0.kind == .deletion }
        let preview = changed.prefix(4).map { ($0.kind == .addition ? "+" : "-") + String($0.text.prefix(120)) }
        let decision = ReviewDecision(t: Date().timeIntervalSince1970, path: path, action: action, scope: scope,
                                      added: changed.filter { $0.kind == .addition }.count, removed: changed.filter { $0.kind == .deletion }.count,
                                      commentOnly: Learning.isCommentOnly(changed.map(\.text), path: path), preview: preview,
                                      batch: aiBatches.last { $0.paths.contains(path) }?.id)
        AppLog.attempt("记录验收决定") { try FolmiShared.append(decision, to: FolmiShared.decisions(gitDir: gitDir)) }
        if action == .reject {
            lastAccept = nil
            lastReject = RecentReject(t: decision.t, path: path)
            refreshLearning()
        } else if lastReject != nil {
            lastReject = nil
        }
    }

    /// The one line on why the last rejection was made. It goes to the agent (`recent_decisions`) and counts as a
    /// note when spotting the same request again.
    func recordRejectReason(_ text: String) {
        let reason = RulesFile.normalizedRule(text)
        guard let reject = lastReject, let gitDir = aiGitDir else { return }
        lastReject = nil
        guard !reason.isEmpty else { return }
        AppLog.attempt("记录丢弃原因") {
            try FolmiShared.append(DecisionReason(t: reject.t, path: reject.path, reason: reason), to: FolmiShared.reasons(gitDir: gitDir))
        }
        refreshLearning()
    }
    func recordFileDecision(_ action: ReviewDecision.Action, _ diff: FileDiff) {
        recordDecision(action, scope: .file, path: diff.file.path, lines: diff.hunks.flatMap(\.lines))
    }

    /// Each new review note, for spotting the same request twice.
    func recordNote(_ comment: ReviewComment) {
        guard let gitDir = aiGitDir else { return }
        AppLog.attempt("记录评论") {
            try FolmiShared.append(NoteRecord(t: comment.created.timeIntervalSince1970, path: comment.path, body: comment.body),
                                       to: Learning.noteLog(gitDir: gitDir))
        }
    }

    var learningState: LearningState {
        aiGitDir.flatMap { FolmiShared.read(LearningState.self, from: Learning.stateFile(gitDir: $0)) } ?? LearningState()
    }
    func saveLearningState(_ state: LearningState) {
        guard let gitDir = aiGitDir else { return }
        AppLog.attempt("保存规则提议状态") { try FolmiShared.write(state, to: Learning.stateFile(gitDir: gitDir)) }
    }

    /// The rules already in the project's CLAUDE.md section.
    var projectRules: [String] {
        guard let root = repositoryURL else { return [] }
        return RulesFile.targets(root: root).flatMap { url in RulesFile.rules(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "") }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    func refreshLearning() {
        guard let gitDir = aiGitDir else { if !ruleProposals.isEmpty { ruleProposals = [] }; return }
        let next = Learning.proposals(decisions: FolmiShared.lines(ReviewDecision.self, from: FolmiShared.decisions(gitDir: gitDir), limit: 2_000),
                                      notes: Self.learningNotes(gitDir: gitDir),
                                      state: learningState, existingRules: projectRules, callTools: suggestsCallTools)
        if next != ruleProposals { ruleProposals = next }
    }

    /// Folmi's MCP is connected for some agent, and the changes under review include JS / TS / Python files.
    var suggestsCallTools: Bool {
        guard snapshot?.files.contains(where: { Self.callMapExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }) == true
        else { return false }
        return MCPInstaller.Client.allCases.contains { MCPInstaller.isInstalled($0) }
    }

    /// Review notes and rejection reasons, oldest first.
    static func learningNotes(gitDir: URL) -> [NoteRecord] {
        let notes = FolmiShared.lines(NoteRecord.self, from: Learning.noteLog(gitDir: gitDir), limit: 500)
        let reasons = FolmiShared.lines(DecisionReason.self, from: FolmiShared.reasons(gitDir: gitDir), limit: 500)
            .map { NoteRecord(t: $0.t, path: $0.path, body: $0.reason, kind: .reject) }
        return (notes + reasons).sorted { $0.t < $1.t }
    }

    func declineProposal(_ proposal: RuleProposal) {
        var state = learningState
        state.declined[proposal.id] = Date().timeIntervalSince1970
        saveLearningState(state)
        refreshLearning()
    }
    func restoreDeclined(_ id: String) {
        var state = learningState
        state.declined[id] = nil
        saveLearningState(state)
        refreshLearning()
    }

    /// Writes the rule into the marked section of CLAUDE.md (and AGENTS.md when present). The files then show up as
    /// ordinary changes to review and commit.
    @discardableResult
    func writeRule(_ rule: String, proposal: String?, preview: RulesFile.WritePreview? = nil) -> Bool {
        guard let root = repositoryURL else { return false }
        let text = RulesFile.normalizedRule(rule)
        guard !text.isEmpty else { return false }
        do {
            let expected = try preview ?? RulesFile.preview(text, root: root)
            guard expected.rule == text else { throw RulesFile.WriteError.changed }
            try RulesFile.write(expected, root: root)
        } catch { report(error, title: "规则没有写入"); return false }
        if let proposal {
            var state = learningState
            if !state.written.contains(proposal) { state.written.append(proposal) }
            saveLearningState(state)
        }
        refreshLearning()
        refreshInBackground()
        record("写入规则", text)
        return true
    }
    func removeRule(_ rule: String) {
        guard let root = repositoryURL else { return }
        do {
            for url in RulesFile.targets(root: root) where FileManager.default.fileExists(atPath: url.path) {
                let current = try String(contentsOf: url, encoding: .utf8)
                let next = RulesFile.removing(rule, from: current)
                if next != current { try next.write(to: url, atomically: true, encoding: .utf8) }
            }
        } catch { report(error, title: "规则没有删除"); return }
        refreshLearning()
        refreshInBackground()
    }

    func clearDecisionLog() {
        guard let gitDir = aiGitDir else { return }
        for url in [FolmiShared.decisions(gitDir: gitDir), FolmiShared.reasons(gitDir: gitDir), Learning.noteLog(gitDir: gitDir)] {
            try? FileManager.default.removeItem(at: url)
        }
        lastReject = nil
        refreshLearning()
    }
    var decisionCount: Int { aiGitDir.map { FolmiShared.lines(ReviewDecision.self, from: FolmiShared.decisions(gitDir: $0)).count } ?? 0 }

    /// Rewords a note-based rule into one instruction for the agent ("总结规则" model). Falls back to the note itself;
    /// `general` is false when the model reads the notes as about particular code rather than a habit.
    func polishRule(_ proposal: RuleProposal) async -> (rule: String, general: Bool) {
        let client = AIClient.client(for: .rules, project: repositoryURL?.path, settings: aiSettings)
        let input = proposal.examples.isEmpty ? proposal.rule : proposal.examples.joined(separator: "\n")
        guard proposal.fromComments, client.isAvailable, SecretScan.findings(in: input).isEmpty else { return (proposal.rule, true) }
        let text = (try? await client.complete(system: AIPrompts.ruleFromNotes, user: input, maxTokens: 200)) ?? ""
        let line = text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: CharacterSet(charactersIn: " -*\"「」。")) ?? ""
        if line.hasPrefix(AIPrompts.notGeneral) { return (proposal.rule, false) }
        return (line.isEmpty ? proposal.rule : line, true)
    }
}

/// On the wrap-up card: one proposal at a time, decided in a click.
struct RuleProposalCard: View {
    let model: FolmiModel
    let proposal: RuleProposal
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(proposal.reason, systemImage: "lightbulb").themedFont(.callout, points: 12)
            Text("要不要让 agent 以后记住：「\(proposal.rule)」").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("写进规则…") { editing = true }.buttonStyle(.folmiProminent)
                Button("不用") { model.declineProposal(proposal) }
            }.controlSize(.small)
        }
        .padding(12).frame(maxWidth: 420, alignment: .leading)
        .background(ThemeColor(token: .accent, opacity: 0.06), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $editing) { RuleWriteSheet(model: model, proposal: proposal).sheetEntrance() }
    }
}

/// The rule text (editable) and the files it goes into, before anything is written.
struct RuleWriteSheet: View {
    let model: FolmiModel
    let proposal: RuleProposal?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var polishing = false
    @State private var notGeneral = false
    @State private var preview: RulesFile.WritePreview?
    @State private var previewError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("写进项目规则").themedFont(.title3.weight(.semibold), points: 15)
            if let proposal { Text(proposal.reason).themedFont(.callout, points: 12).foregroundStyle(.secondary) }
            TextField("给 agent 的一句要求", text: $text, axis: .vertical).lineLimit(2...4).themedTextField()
            let files = model.repositoryURL.map { RulesFile.targets(root: $0).map(\.lastPathComponent).joined(separator: "、") } ?? ""
            Text("会写进 \(files) 末尾带标记的「\(RulesFile.heading.dropFirst(3))」一段，文件里其他内容不动。写完它会作为普通改动出现在改动列表里，提不提交由你决定。")
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if notGeneral {
                Label("模型觉得这些话更像是针对某几处代码的意见，不一定适合写成长期规则。", systemImage: "exclamationmark.triangle")
                    .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let previewError {
                Text(previewError).themedFont(.caption, points: 10).foregroundStyle(ThemeColor(token: .removed))
            }
            if let preview {
                Text("写入预览").themedFont(.callout.weight(.semibold), points: 12)
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(preview.changes) { change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.url.lastPathComponent).themedFont(.callout.weight(.semibold), points: 12)
                                if change.hasChanges {
                                    Text(change.diff).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                } else {
                                    Text("已有相同规则，无需修改。").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(height: 220).background(ThemeColor(token: .canvas), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                if polishing { ProgressView().controlSize(.small); Text("正在改写…").themedFont(.caption, points: 10).foregroundStyle(.secondary) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("写入") {
                    guard let preview else { return }
                    if model.writeRule(text, proposal: proposal?.id, preview: preview) { dismiss() }
                    else { updatePreview() }
                }
                    .keyboardShortcut(.defaultAction).buttonStyle(.folmiProminent)
                    .disabled(RulesFile.normalizedRule(text).isEmpty || preview == nil || polishing)
            }
        }
        .padding(20).frame(width: 620)
        .onChange(of: text) { _, _ in updatePreview() }
        .task {
            text = proposal?.rule ?? ""
            updatePreview()
            guard let proposal, proposal.fromComments else { return }
            polishing = true
            let polished = await model.polishRule(proposal)
            if text == proposal.rule { text = polished.rule }
            notGeneral = !polished.general
            polishing = false
        }
    }

    private func updatePreview() {
        preview = nil
        previewError = nil
        guard let root = model.repositoryURL else { return }
        do { preview = try RulesFile.preview(text, root: root) }
        catch { previewError = error.localizedDescription }
    }
}

/// 记住了什么: every rule written, every proposal declined, and the logs behind them. All of it can be removed here.
struct MemorySheet: View {
    @Bindable var model: FolmiModel
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        let rules = model.projectRules
        let declined = model.learningState.declined.sorted { $0.value > $1.value }
        VStack(alignment: .leading, spacing: 12) {
            Text("记住了什么").themedFont(.title3.weight(.semibold), points: 15)
            Text("工作台只会在你同意后把规则写进项目文件；这里的每一项都可以删。").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            Form {
                Section("写进项目的要求（CLAUDE.md / AGENTS.md）") {
                    if rules.isEmpty { Text("还没有").foregroundStyle(.secondary) }
                    ForEach(rules, id: \.self) { rule in
                        HStack(alignment: .top) {
                            Text(rule).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("删除") { model.removeRule(rule); refresh += 1 }.controlSize(.small)
                        }
                    }
                    Button("自己加一条…") { adding = true }.controlSize(.small)
                }
                if !model.ruleProposals.isEmpty {
                    Section("等你决定的提议") {
                        ForEach(model.ruleProposals) { proposal in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proposal.reason).themedFont(.callout, points: 12)
                                Text(proposal.rule).themedFont(.caption, points: 10).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("没采纳的提议（30 天内不再提）") {
                    if declined.isEmpty { Text("没有").foregroundStyle(.secondary) }
                    ForEach(declined, id: \.key) { item in
                        HStack {
                            Text(Self.describe(item.key)).lineLimit(1)
                            Spacer()
                            Button("恢复") { model.restoreDeclined(item.key); refresh += 1 }.controlSize(.small)
                        }
                    }
                }
                Section("记录") {
                    HStack {
                        Text("验收决定 \(model.decisionCount) 条，含丢弃原因（仅保存在本仓库的本地记录中）")
                        Spacer()
                        Button("清空") { model.clearDecisionLog(); refresh += 1 }.controlSize(.small)
                    }
                    HStack {
                        Text("⌘K 常用记录 \(model.paletteUsage.records.count) 条")
                        Spacer()
                        Button("清空") { model.paletteUsage = PaletteUsage(); model.paletteUsage.save(); refresh += 1 }.controlSize(.small)
                    }
                }
            }
            .formStyle(.grouped).frame(minHeight: 380)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 580)
        .onAppear { model.refreshLearning() }
        .sheet(isPresented: $adding, onDismiss: { refresh += 1 }) { RuleWriteSheet(model: model, proposal: nil).sheetEntrance() }
    }

    static func describe(_ key: String) -> String {
        if key == "lockfiles" { return "不要修改依赖锁文件" }
        if key == "comments" { return "不要只加注释" }
        if key.hasPrefix("path:") { return "不要修改 \(key.dropFirst(5))" }
        return "一组相似的评论"
    }
}
