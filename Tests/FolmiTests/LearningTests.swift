import XCTest
@testable import FolmiCore
@testable import Folmi

final class LearningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000_000)
    private func decision(_ path: String, _ action: ReviewDecision.Action, ago: Double = 60, commentOnly: Bool = false) -> ReviewDecision {
        ReviewDecision(t: now.timeIntervalSince1970 - ago, path: path, action: action, scope: .hunk, added: 1, removed: 0,
                       commentOnly: commentOnly, preview: [], batch: nil)
    }
    private func ids(_ decisions: [ReviewDecision], notes: [NoteRecord] = [], state: LearningState = LearningState(), rules: [String] = []) -> [String] {
        Learning.proposals(decisions: decisions, notes: notes, state: state, existingRules: rules, now: now).map(\.id)
    }

    func testThreeRejectsOfLockfilesOrOneFileArePropsed() {
        XCTAssertEqual(ids([decision("package-lock.json", .reject), decision("app/yarn.lock", .reject)]), [], "two is not a pattern yet")
        XCTAssertEqual(ids([decision("package-lock.json", .reject), decision("app/yarn.lock", .reject), decision("Package.resolved", .reject)]),
                       ["lockfiles"])
        let config = [decision("config.json", .reject), decision("config.json", .reject), decision("config.json", .reject)]
        XCTAssertEqual(ids(config), ["path:config.json"])
        XCTAssertEqual(ids(config + [decision("config.json", .accept), decision("config.json", .accept), decision("config.json", .accept)]), [],
                       "a file accepted as often as rejected is not a pattern")
        XCTAssertEqual(ids(config.map { decision($0.path, .reject, ago: 40 * 86_400) }), [], "old decisions fall out of the window")
    }

    func testCommentOnlyRejects() {
        let rejects = (0..<3).map { decision("f\($0).swift", .reject, commentOnly: true) }
        XCTAssertEqual(ids(rejects), ["comments"])
        XCTAssertTrue(Learning.isCommentOnly(["// explain", "  ", "/* more */"], path: "a.swift"))
        XCTAssertTrue(Learning.isCommentOnly(["# note"], path: "tool.py"))
        XCTAssertTrue(Learning.isCommentOnly(["# note"], path: "Makefile"))
        XCTAssertFalse(Learning.isCommentOnly(["// explain", "let x = 1"], path: "a.swift"))
        XCTAssertFalse(Learning.isCommentOnly([], path: "a.swift"))
    }

    func testProseIsNeverCommentOnly() {
        // A Markdown heading or list item starts like a comment in other languages.
        XCTAssertFalse(Learning.isCommentOnly(["## 安装", "* 第一步", "-- 分隔"], path: "docs/guide.md"))
        XCTAssertFalse(Learning.isCommentOnly(["# 标题"], path: "notes.txt"))
        XCTAssertFalse(Learning.isCommentOnly(["# x"], path: "unknown.zzz"))
        XCTAssertFalse(Learning.isCommentOnly(["// x"], path: "tool.py"), "each file type uses its own markers")
        XCTAssertTrue(Learning.isCommentOnly(["<!-- todo -->"], path: "index.html"))
    }

    func testNotesAboutOneFileAreNotARule() {
        let notes = [NoteRecord(t: now.timeIntervalSince1970 - 100, path: "a.swift", body: "这个变量名太短了"),
                     NoteRecord(t: now.timeIntervalSince1970 - 50, path: "a.swift", body: "这个变量名太短")]
        XCTAssertEqual(ids([], notes: notes), [], "the same note on one file is about that spot")
    }

    func testRejectReasonsCountWithNotes() {
        let notes = [NoteRecord(t: now.timeIntervalSince1970 - 100, path: "a.swift", body: "不要新建总结文档", kind: .reject),
                     NoteRecord(t: now.timeIntervalSince1970 - 50, path: "SUMMARY.md", body: "不要新建总结文档。", kind: .reject)]
        let proposals = Learning.proposals(decisions: [], notes: notes, state: LearningState(), existingRules: [], now: now)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertTrue(proposals[0].reason.contains("丢弃原因"))
        XCTAssertEqual(proposals[0].examples.count, 2)
        XCTAssertTrue(proposals[0].examples.contains { $0.hasPrefix("SUMMARY.md：") }, "the model sees each note with its file")
    }

    func testNoteRecordsWithoutKindStillDecode() throws {
        let old = try JSONDecoder().decode(NoteRecord.self, from: Data(#"{"t":1,"path":"a","body":"x"}"#.utf8))
        XCTAssertEqual(old.kind, .comment)
    }

    func testSimilarNotesTwiceAreProposed() {
        let notes = [NoteRecord(t: now.timeIntervalSince1970 - 100, path: "a", body: "这里不要用强制解包"),
                     NoteRecord(t: now.timeIntervalSince1970 - 50, path: "b", body: "不要用强制解包！"),
                     NoteRecord(t: now.timeIntervalSince1970 - 10, path: "c", body: "变量名太短")]
        let proposals = Learning.proposals(decisions: [], notes: notes, state: LearningState(), existingRules: [], now: now)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertTrue(proposals[0].fromComments)
        XCTAssertTrue(proposals[0].reason.contains("2 次"))
    }

    func testDeclinedWaitsAndWrittenOrExistingRulesAreNotProposedAgain() {
        let rejects = (0..<3).map { _ in decision("package-lock.json", .reject) }
        XCTAssertEqual(ids(rejects, state: LearningState(declined: ["lockfiles": now.timeIntervalSince1970 - 86_400])), [])
        XCTAssertEqual(ids(rejects, state: LearningState(declined: ["lockfiles": now.timeIntervalSince1970 - 31 * 86_400])), ["lockfiles"])
        XCTAssertEqual(ids(rejects, state: LearningState(written: ["lockfiles"])), [])
        XCTAssertEqual(ids(rejects, rules: ["除非任务明确要求，不要修改依赖锁文件（package-lock.json、yarn.lock、Package.resolved 等）。"]), [])
    }

    func testRulesSectionOnlyTouchesItsOwnText() {
        let original = "# 项目说明\n\n别的内容。\n"
        let one = RulesFile.adding("不要改 lockfile。", to: original)
        XCTAssertTrue(one.hasPrefix(original))
        XCTAssertEqual(RulesFile.rules(in: one), ["不要改 lockfile。"])
        let two = RulesFile.adding("少写注释。", to: one)
        XCTAssertEqual(RulesFile.rules(in: two), ["不要改 lockfile。", "少写注释。"])
        XCTAssertEqual(RulesFile.adding("少写注释。", to: two), two, "adding the same rule twice changes nothing")
        // Text after the section survives an update.
        let withTail = two + "\n## 之后加的\n尾巴\n"
        let removed = RulesFile.removing("不要改 lockfile。", from: withTail)
        XCTAssertEqual(RulesFile.rules(in: removed), ["少写注释。"])
        XCTAssertTrue(removed.hasPrefix(original)); XCTAssertTrue(removed.hasSuffix("## 之后加的\n尾巴\n"))
        let empty = RulesFile.removing("少写注释。", from: RulesFile.removing("不要改 lockfile。", from: two))
        XCTAssertFalse(empty.contains(RulesFile.start))
        XCTAssertTrue(empty.hasPrefix(original))
        XCTAssertEqual(RulesFile.rules(in: RulesFile.adding("x", to: "")), ["x"], "a missing file gets just the section")
    }

    private func ruleFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRulePreviewShowsBothFilesAndWritesTheExactReviewedBytes() throws {
        let root = try ruleFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("CLAUDE.md"), agents = root.appendingPathComponent("AGENTS.md")
        let original = RulesFile.adding("已有要求。", to: "# 原有内容\n\n正文\n") + "\n## 尾部\n保留这段\n"
        try original.write(to: claude, atomically: true, encoding: .utf8)
        try "# Codex 要求\n".write(to: agents, atomically: true, encoding: .utf8)

        let preview = try RulesFile.preview("  不要改锁文件。\r\n保持原格式。  ", root: root)
        XCTAssertEqual(preview.rule, "不要改锁文件。 保持原格式。")
        XCTAssertEqual(preview.changes.map(\.url), [claude, agents])
        XCTAssertEqual(try String(contentsOf: claude, encoding: .utf8), original, "preview is read-only")
        for change in preview.changes {
            XCTAssertTrue(change.diff.contains("+++ b/" + change.url.lastPathComponent))
            XCTAssertTrue(change.diff.contains("+- " + preview.rule))
        }
        try RulesFile.write(preview, root: root)
        for change in preview.changes { XCTAssertEqual(try Data(contentsOf: change.url), change.after) }
        let written = try String(contentsOf: claude, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("# 原有内容\n\n正文\n"))
        XCTAssertTrue(written.hasSuffix("\n## 尾部\n保留这段\n"))
        XCTAssertEqual(RulesFile.rules(in: written), ["已有要求。", preview.rule])
        XCTAssertTrue(try RulesFile.preview(preview.rule, root: root).changes.allSatisfy { !$0.hasChanges && $0.diff.isEmpty })
    }

    func testRulePreviewRefreshUsesTheEditedRuleAndHandlesANewFile() throws {
        let root = try ruleFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RulesFile.preview("原始规则", root: root)
        let edited = try RulesFile.preview("改过的规则", root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("CLAUDE.md").path))
        let change = try XCTUnwrap(edited.changes.first)
        XCTAssertNil(change.before)
        XCTAssertTrue(first.changes[0].diff.contains("+- 原始规则"))
        XCTAssertTrue(change.diff.hasPrefix("--- /dev/null\n+++ b/CLAUDE.md\n@@ -0,0 +1,5 @@\n"))
        XCTAssertTrue(change.diff.contains("+- 改过的规则"))
        XCTAssertFalse(change.diff.contains("原始规则"))
        try RulesFile.write(edited, root: root)
        XCTAssertEqual(try Data(contentsOf: change.url), change.after)
    }

    func testStaleRulePreviewRejectsBeforeWritingAnyTarget() throws {
        let root = try ruleFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("CLAUDE.md"), agents = root.appendingPathComponent("AGENTS.md")
        try "# Claude\n".write(to: claude, atomically: true, encoding: .utf8)
        try "# Agents\n".write(to: agents, atomically: true, encoding: .utf8)
        let preview = try RulesFile.preview("新规则", root: root)
        try "# Agents\n用户刚写的内容\n".write(to: agents, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RulesFile.write(preview, root: root))
        XCTAssertEqual(try String(contentsOf: claude, encoding: .utf8), "# Claude\n")
        XCTAssertEqual(try String(contentsOf: agents, encoding: .utf8), "# Agents\n用户刚写的内容\n")
    }

    func testRulePreviewDetectsNewTargetsAndUnreadableText() throws {
        let root = try ruleFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try RulesFile.preview("新规则", root: root)
        let agents = root.appendingPathComponent("AGENTS.md")
        try "# 新文件\n".write(to: agents, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RulesFile.write(preview, root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("CLAUDE.md").path))
        let invalid = Data([0xFF, 0xFE, 0x80])
        try invalid.write(to: agents)
        XCTAssertThrowsError(try RulesFile.preview("新规则", root: root))
        XCTAssertEqual(try Data(contentsOf: agents), invalid)
    }

    func testRuleUnifiedPreviewPreservesMissingNewlineAndCanBeApplied() throws {
        let root = try ruleFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("CLAUDE.md")
        try "原文没有末尾换行".write(to: claude, atomically: true, encoding: .utf8)
        let preview = try RulesFile.preview("新规则", root: root)
        let change = try XCTUnwrap(preview.changes.first)
        XCTAssertTrue(change.diff.contains("-原文没有末尾换行\n\\ No newline at end of file\n"))
        let patch = root.appendingPathComponent("preview.patch")
        try change.diff.write(to: patch, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["apply", "--", patch.path]
        process.currentDirectoryURL = root
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(try Data(contentsOf: claude), change.after, "displayed diff must reconstruct the exact write")
    }

    func testCommitStyleFollowsTheRepository() {
        XCTAssertTrue(AIPrompts.usesConventionalCommits(["feat: a", "fix(ui): b", "chore: c"]))
        XCTAssertFalse(AIPrompts.usesConventionalCommits(["AI 设置：多个服务商", "收尾小项：减弱动态效果", "feat: x"]))
        XCTAssertTrue(AIPrompts.usesConventionalCommits([]))
        XCTAssertFalse(AIPrompts.commitMessage(chinese: true, conventional: false).contains("allowed types"))
    }

    @MainActor
    func testRejectingRecordsDecisionsAndWritingARuleLandsInClaudeMD() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("learning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: settings) }
        let demo = try await DemoRepository.create()
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.aiSettings.autoCommitMessage = false
        model.open(demo.root, environment: demo.environment, demo: true)
        let deadline = Date().addingTimeInterval(10)
        while model.busy || model.snapshot == nil { try await Task.sleep(nanoseconds: 50_000_000); if Date() > deadline { return XCTFail("open") } }
        let gitDir = try XCTUnwrap(model.aiGitDir)

        for _ in 0..<3 { model.recordDecision(.reject, scope: .hunk, path: "package-lock.json", lines: [DiffLine(id: 1, text: "x", kind: .addition)]) }
        XCTAssertEqual(FolmiShared.lines(ReviewDecision.self, from: FolmiShared.decisions(gitDir: gitDir)).count, 3)
        XCTAssertEqual(model.ruleProposals.map(\.id), ["lockfiles"])

        let proposal = try XCTUnwrap(model.ruleProposals.first)
        model.writeRule(proposal.rule, proposal: proposal.id)
        let claude = try String(contentsOf: demo.root.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        XCTAssertEqual(RulesFile.rules(in: claude), [proposal.rule])
        XCTAssertEqual(model.projectRules, [proposal.rule])
        XCTAssertTrue(model.ruleProposals.isEmpty)
        model.removeRule(proposal.rule)
        XCTAssertTrue(model.projectRules.isEmpty)
        XCTAssertTrue(model.ruleProposals.isEmpty, "a written proposal is not offered again after its rule is removed")
    }
}
