import XCTest
@testable import FolmiCore

private final class ActionFixture {
    let directory: URL
    let home: URL
    let environment: [String: String]
    let repo: GitRepository
    init(directoryName: String = "repo") throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-test-" + UUID().uuidString, isDirectory: true)
        directory = temp.appendingPathComponent(directoryName, isDirectory: true)
        home = temp.appendingPathComponent("isolated-home", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        repo = GitRepository(url: directory, environment: environment)
        _ = try git(["init", "--template=", "--initial-branch=main"])
        _ = try git(["config", "user.name", "Folmi Test"])
        _ = try git(["config", "user.email", "folmi@example.invalid"])
        _ = try git(["config", "core.hooksPath", "/dev/null"])
        _ = try git(["config", "commit.gpgsign", "false"])
    }
    deinit { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    @discardableResult func git(_ args: [String]) throws -> String { try GitProcess(directory: directory, environment: environment).run(args).text }
    func write(_ path: String, _ text: String) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func read(_ path: String) throws -> String { try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8) }
    func initial(_ path: String = "sample.txt", _ text: String = "one\ntwo\nthree\nfour\nfive\nsix\n") throws {
        try write(path, text); try git(["add", "--", path]); try git(["commit", "-m", "Initial"])
    }
    func index(_ path: String = "sample.txt") throws -> String { try git(["show", ":" + path]) }
}



final class CommitActionTests: XCTestCase {
    private func head(_ f: ActionFixture) throws -> String { try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func fingerprint(_ f: ActionFixture) async throws -> String { try await f.repo.load().fingerprint }

    func testRewordChangesOnlyTheLatestUnpushedMessage() async throws {
        let f = try ActionFixture()
        try f.initial()
        try f.write("sample.txt", "changed\n"); try f.git(["commit", "-am", "Second"])
        let second = try head(f)
        // Staged work stays staged and out of the reworded commit.
        try f.write("other.txt", "x\n"); try f.git(["add", "other.txt"])
        let new = try await f.repo.reword(second, message: "Second, better\n", expectedFingerprint: try await fingerprint(f))
        XCTAssertNotEqual(new, second)
        XCTAssertEqual(try f.git(["log", "-1", "--format=%B"]).trimmingCharacters(in: .whitespacesAndNewlines), "Second, better")
        XCTAssertEqual(try f.git(["show", "--name-only", "--format=", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), "sample.txt")
        XCTAssertEqual(try f.git(["diff", "--cached", "--name-only"]).trimmingCharacters(in: .whitespacesAndNewlines), "other.txt")
        // Not the latest commit: refused.
        let first = try f.git(["rev-parse", "HEAD~1"]).trimmingCharacters(in: .whitespacesAndNewlines)
        do { _ = try await f.repo.reword(first, message: "x", expectedFingerprint: try await fingerprint(f)); XCTFail("只能改最新提交") }
        catch {}
    }

    func testRewordRefusesAPushedCommit() async throws {
        let f = try ActionFixture()
        try f.initial()
        let remote = f.directory.deletingLastPathComponent().appendingPathComponent("remote.git")
        try f.git(["init", "--bare", "--template=", remote.path])
        try f.git(["remote", "add", "origin", remote.path]); try f.git(["push", "-q", "origin", "main"]); try f.git(["fetch", "-q", "origin"])
        let ability = try await f.repo.abilities(of: try head(f))
        XCTAssertTrue(ability.pushed); XCTAssertTrue(ability.isHead)
        do { _ = try await f.repo.reword(try head(f), message: "x", expectedFingerprint: try await fingerprint(f)); XCTFail("已推送不能改") }
        catch {}
        let unpushed = try await f.repo.load().unpushed
        XCTAssertEqual(unpushed, 0)
    }

    func testRevertAndCherryPickLandInTheStagingArea() async throws {
        let f = try ActionFixture()
        try f.initial()
        try f.write("sample.txt", "one\nTWO\nthree\nfour\nfive\nsix\n"); try f.git(["commit", "-am", "Shout two"])
        let shout = try head(f)
        let staged = try await f.repo.applyCommit(shout, kind: .revert, expectedFingerprint: try await fingerprint(f))
        XCTAssertEqual(staged, ["sample.txt"])
        XCTAssertEqual(try f.index(), "one\ntwo\nthree\nfour\nfive\nsix\n")
        XCTAssertEqual(try head(f), shout, "没有自动提交")
        let message = try await f.repo.suggestedMessage(for: shout, kind: .revert)
        XCTAssertTrue(message.hasPrefix("Revert \"Shout two\""), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(".git/REVERT_HEAD").path))

        // Cherry-pick a commit from another branch.
        try f.git(["reset", "-q", "--hard", "HEAD"])
        try f.git(["switch", "-q", "-c", "side"]); try f.write("side.txt", "side\n"); try f.git(["add", "side.txt"]); try f.git(["commit", "-qm", "Side file"])
        let side = try head(f)
        try f.git(["switch", "-q", "main"])
        let onMain = try await f.repo.abilities(of: side)
        XCTAssertFalse(onMain.onCurrentBranch)
        let picked = try await f.repo.applyCommit(side, kind: .cherryPick, expectedFingerprint: try await fingerprint(f))
        XCTAssertEqual(picked, ["side.txt"])
        XCTAssertEqual(try f.read("side.txt"), "side\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(".git/CHERRY_PICK_HEAD").path))
    }

    func testApplyNeedsACleanTreeAndRollsBackAConflict() async throws {
        let f = try ActionFixture()
        try f.initial()
        try f.write("sample.txt", "one\nTWO\nthree\nfour\nfive\nsix\n"); try f.git(["commit", "-am", "Shout two"])
        let shout = try head(f)
        try f.write("sample.txt", "dirty\n")
        do { _ = try await f.repo.applyCommit(shout, kind: .revert, expectedFingerprint: try await fingerprint(f)); XCTFail("工作区不干净") }
        catch {}
        XCTAssertEqual(try f.read("sample.txt"), "dirty\n", "用户的改动不能动")
        try f.git(["checkout", "--", "sample.txt"])
        // A later commit rewrites the same line, so reverting the earlier one conflicts.
        try f.write("sample.txt", "one\nTwo!\nthree\nfour\nfive\nsix\n"); try f.git(["commit", "-am", "Again"])
        let before = try head(f)
        do { _ = try await f.repo.applyCommit(shout, kind: .revert, expectedFingerprint: try await fingerprint(f)); XCTFail("应当冲突") }
        catch { XCTAssertTrue("\(error)".contains("冲突") || (error as? LocalizedError)?.errorDescription?.contains("冲突") == true, "\(error)") }
        XCTAssertEqual(try head(f), before)
        let files = try await f.repo.load().files
        XCTAssertTrue(files.isEmpty, "冲突后恢复原样")
    }

    func testBranchFromACommitAndCompareTwoCommits() async throws {
        let f = try ActionFixture()
        try f.initial()
        let first = try head(f)
        try f.write("a.txt", "a\n"); try f.git(["add", "a.txt"]); try f.git(["commit", "-qm", "Add a"])
        try f.write("sample.txt", "changed\n"); try f.git(["commit", "-qam", "Change sample"])
        try await f.repo.createBranch("fix/old", at: first)
        XCTAssertEqual(try f.git(["rev-parse", "fix/old"]).trimmingCharacters(in: .whitespacesAndNewlines), first)
        XCTAssertEqual(try f.git(["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines), "main", "不切换")
        do { try await f.repo.createBranch("fix/old", at: first); XCTFail("重名") } catch {}
        do { try await f.repo.createBranch("bad name", at: first); XCTFail("无效名") } catch {}
        let compared = try await f.repo.compareDetail(base: first, target: try head(f))
        XCTAssertEqual(Set(compared.files.map(\.path)), ["a.txt", "sample.txt"])
        let diff = try await f.repo.compareDiff(base: first, target: try head(f), file: try XCTUnwrap(compared.files.first { $0.path == "sample.txt" }))
        XCTAssertTrue(diff.rawPatch.contains("+changed"))
    }

    func testUndoTakesARevertBackOut() async throws {
        let f = try ActionFixture()
        try f.initial()
        try f.write("new.txt", "new\n"); try f.git(["add", "new.txt"]); try f.git(["commit", "-qm", "Add new"])
        let added = try head(f)
        // What the app captures before reverting: index and work tree of the commit's files.
        let step = UndoStep.group([try await f.repo.captureIndex(["new.txt"]), try await f.repo.captureWorktree(["new.txt"])])
        _ = try await f.repo.applyCommit(added, kind: .revert, expectedFingerprint: try await fingerprint(f))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("new.txt").path))
        _ = try await f.repo.undo(step)
        XCTAssertEqual(try f.read("new.txt"), "new\n")
        let files = try await f.repo.load().files
        XCTAssertTrue(files.isEmpty, "\(files)")
    }
}

final class RollbackTests: XCTestCase {
    private func rev(_ f: ActionFixture, _ name: String) throws -> String { try f.git(["rev-parse", name]).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func fingerprint(_ f: ActionFixture) async throws -> String { try await f.repo.load().fingerprint }

    private func threeCommits() throws -> ActionFixture {
        let f = try ActionFixture()
        try f.initial()
        try f.write("sample.txt", "second\n"); try f.git(["commit", "-am", "Second"])
        try f.write("added.txt", "new\n"); try f.git(["add", "added.txt"]); try f.git(["commit", "-m", "Third"])
        return f
    }

    func testKeepChangesMovesTheBranchAndStagesTheDroppedWork() async throws {
        let f = try threeCommits()
        let first = try rev(f, "HEAD~2"), third = try rev(f, "HEAD")
        let plan = try await f.repo.rollbackPlan(to: first)
        XCTAssertEqual(plan.commits, 2); XCTAssertEqual(plan.pushed, 0); XCTAssertEqual(plan.branch, "refs/heads/main")
        let step = try await f.repo.rollback(plan, mode: .keepChanges, expectedFingerprint: try await fingerprint(f))
        XCTAssertEqual(try rev(f, "HEAD"), first)
        XCTAssertEqual(try f.read("sample.txt"), "second\n")
        XCTAssertEqual(try f.git(["diff", "--cached", "--name-only"]), "added.txt\nsample.txt\n")
        _ = try await f.repo.undo(step)
        XCTAssertEqual(try rev(f, "HEAD"), third)
        XCTAssertEqual(try f.git(["status", "--porcelain"]), "")
    }

    func testDiscardChangesPutsFilesBackKeepsUnrelatedWorkAndUndoes() async throws {
        let f = try threeCommits()
        try f.write("notes.txt", "mine\n")
        let first = try rev(f, "HEAD~2"), third = try rev(f, "HEAD")
        let plan = try await f.repo.rollbackPlan(to: first)
        let step = try await f.repo.rollback(plan, mode: .discardChanges, expectedFingerprint: try await fingerprint(f))
        XCTAssertEqual(try rev(f, "HEAD"), first)
        XCTAssertEqual(try f.read("sample.txt"), "one\ntwo\nthree\nfour\nfive\nsix\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("added.txt").path))
        XCTAssertEqual(try f.read("notes.txt"), "mine\n")
        _ = try await f.repo.undo(step)
        XCTAssertEqual(try rev(f, "HEAD"), third)
        XCTAssertEqual(try f.read("sample.txt"), "second\n")
        XCTAssertEqual(try f.git(["status", "--porcelain"]), "?? notes.txt\n")
    }

    func testDiscardRefusesWhenUncommittedWorkWouldBeOverwritten() async throws {
        let f = try threeCommits()
        try f.write("sample.txt", "edited\n")
        let first = try rev(f, "HEAD~2"), third = try rev(f, "HEAD")
        let plan = try await f.repo.rollbackPlan(to: first)
        do { _ = try await f.repo.rollback(plan, mode: .discardChanges, expectedFingerprint: try await fingerprint(f)); XCTFail("会覆盖改动") }
        catch {}
        XCTAssertEqual(try rev(f, "HEAD"), third)
        XCTAssertEqual(try f.read("sample.txt"), "edited\n")
    }

    func testPlanRefusesHeadAndCountsPushedCommits() async throws {
        let f = try threeCommits()
        do { _ = try await f.repo.rollbackPlan(to: try rev(f, "HEAD")); XCTFail("已经在这里") } catch {}
        try f.git(["update-ref", "refs/remotes/origin/main", "HEAD~1"])
        let plan = try await f.repo.rollbackPlan(to: try rev(f, "HEAD~2"))
        XCTAssertEqual(plan.commits, 2); XCTAssertEqual(plan.pushed, 1)
    }

    func testRestoreFileBeforeAndAfterACommit() async throws {
        let f = try threeCommits()
        let second = try rev(f, "HEAD~1"), third = try rev(f, "HEAD")
        try await f.repo.restoreFile("sample.txt", from: second, side: .before)
        XCTAssertEqual(try f.read("sample.txt"), "one\ntwo\nthree\nfour\nfive\nsix\n")
        try await f.repo.restoreFile("sample.txt", from: second, side: .after)
        XCTAssertEqual(try f.read("sample.txt"), "second\n")
        // Before the commit that added it, the file did not exist.
        try await f.repo.restoreFile("added.txt", from: third, side: .before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("added.txt").path))
        XCTAssertEqual(try rev(f, "HEAD"), third)
    }
}

final class ConflictTests: XCTestCase {
    func testParsesBlocksAndSettlesOneAtATime() {
        let text = "top\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> feature\nmiddle\n<<<<<<< HEAD\na\n||||||| base\nb\n=======\nc\n>>>>>>> feature\nend\n"
        let file = ConflictFile(text)
        XCTAssertEqual(file.blocks.count, 2)
        XCTAssertEqual(file.blocks[0].oursLabel, "HEAD"); XCTAssertEqual(file.blocks[0].theirsLabel, "feature")
        XCTAssertEqual(file.blocks[1].base, "b\n")
        XCTAssertEqual(file.resolvingAll(with: .ours), "top\nmine\nmiddle\na\nend\n")
        let first = file.resolving(0, with: .oursThenTheirs)!
        XCTAssertTrue(first.hasPrefix("top\nmine\ntheirs\nmiddle\n<<<<<<< HEAD\n"))
        XCTAssertEqual(ConflictFile(first).blocks.count, 1)
        XCTAssertEqual(ConflictFile(first).resolving(0, with: .theirs), "top\nmine\ntheirs\nmiddle\nc\nend\n")
    }

    func testCRLFAndUnclosedMarkersSurvive() {
        let file = ConflictFile("<<<<<<< HEAD\r\nx\r\n=======\r\ny\r\n>>>>>>> b\r\ntail")
        XCTAssertEqual(file.resolvingAll(with: .theirs), "y\r\ntail")
        XCTAssertEqual(ConflictFile("<<<<<<< HEAD\nonly\n").blocks.count, 0)
        XCTAssertEqual(ConflictFile("<<<<<<< HEAD\nonly\n").resolvingAll(with: .ours), "<<<<<<< HEAD\nonly\n")
    }

    func testRealMergeConflictResolvesAndStages() async throws {
        let f = try ActionFixture()
        try f.initial("a.txt", "one\n")
        try f.git(["switch", "-c", "feature"]); try f.write("a.txt", "feature\n"); try f.git(["commit", "-am", "F"])
        try f.git(["switch", "main"]); try f.write("a.txt", "main\n"); try f.git(["commit", "-am", "M"])
        _ = try? f.git(["merge", "feature"])
        let file = try await f.repo.conflictFile("a.txt")!
        XCTAssertEqual(file.blocks.count, 1)
        do { try await f.repo.markResolved("a.txt"); XCTFail("还有冲突") } catch {}
        try await f.repo.resolveConflict("a.txt", block: 0, choice: .theirsThenOurs, expected: file)
        XCTAssertEqual(try f.read("a.txt"), "feature\nmain\n")
        try await f.repo.markResolved("a.txt")
        let after = try await f.repo.load()
        XCTAssertFalse(after.files.contains(where: \.isConflict))
    }
}

final class WorktreeTests: XCTestCase {
    func testListsWorktreesAndFindsTheMainCheckout() async throws {
        let f = try ActionFixture()
        try f.initial()
        let extra = f.directory.deletingLastPathComponent().appendingPathComponent("agent-tree")
        try f.git(["worktree", "add", "-b", "agent/fix", extra.path])
        let list = try await f.repo.worktrees()
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].isMain); XCTAssertEqual(list[0].branch, "main")
        XCTAssertEqual(list[1].branch, "agent/fix"); XCTAssertFalse(list[1].isMain)
        let canonical = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        XCTAssertEqual(WorktreeInfo.mainRoot(of: extra.path).map(canonical), canonical(f.directory.path))
        XCTAssertNil(WorktreeInfo.mainRoot(of: f.directory.path))
    }

    func testParseSkipsBareAndPrunable() {
        let text = "worktree /a\nbare\n\nworktree /b\nHEAD 1234567890\ndetached\n\nworktree /c\nHEAD ff\nbranch refs/heads/x\nprunable gitdir file points to non-existent location\n"
        let list = WorktreeInfo.parse(text)
        XCTAssertEqual(list.map(\.path), ["/b"])
        XCTAssertEqual(list[0].title, "1234567"); XCTAssertFalse(list[0].isMain)
    }
}

final class RefTests: XCTestCase {
    private func rev(_ f: ActionFixture, _ name: String) throws -> String { try f.git(["rev-parse", name]).trimmingCharacters(in: .whitespacesAndNewlines) }

    func testDeleteBranchWarnsAboutOwnCommitsAndUndoes() async throws {
        let f = try ActionFixture()
        try f.initial()
        try f.git(["branch", "merged"])
        try f.git(["switch", "-c", "work"]); try f.write("sample.txt", "x\n"); try f.git(["commit", "-am", "W"]); try f.git(["switch", "main"])
        let mergedOwn = try await f.repo.branchHasOwnCommits("merged")
        let workOwn = try await f.repo.branchHasOwnCommits("work")
        XCTAssertFalse(mergedOwn); XCTAssertTrue(workOwn)
        let work = try rev(f, "work")
        let step = try await f.repo.deleteBranch("work")
        XCTAssertEqual(try f.git(["branch", "--list", "work"]), "")
        _ = try await f.repo.undo(step)
        XCTAssertEqual(try rev(f, "work"), work)
        do { _ = try await f.repo.deleteBranch("main"); XCTFail("当前分支") } catch {}
    }

    func testRenameCurrentBranchAndUndo() async throws {
        let f = try ActionFixture()
        try f.initial()
        let step = try await f.repo.renameBranch("main", to: "trunk")
        XCTAssertEqual(try f.git(["symbolic-ref", "--short", "HEAD"]), "trunk\n")
        do { _ = try await f.repo.renameBranch("trunk", to: "bad name"); XCTFail("无效名") } catch {}
        _ = try await f.repo.undo(step)
        XCTAssertEqual(try f.git(["symbolic-ref", "--short", "HEAD"]), "main\n")
    }

    func testTagsCreateAnnotatedOrLightAndUndo() async throws {
        let f = try ActionFixture()
        try f.initial()
        let head = try rev(f, "HEAD")
        let light = try await f.repo.createTag("v1", at: head, message: "")
        let annotated = try await f.repo.createTag("v2", at: head, message: "第二版")
        XCTAssertEqual(try f.git(["cat-file", "-t", "v1"]), "commit\n")
        XCTAssertEqual(try f.git(["cat-file", "-t", "v2"]), "tag\n")
        let tags = try await f.repo.tags(at: head)
        XCTAssertEqual(tags, ["v1", "v2"])
        do { _ = try await f.repo.createTag("v1", at: head, message: ""); XCTFail("重复") } catch {}
        _ = try await f.repo.undo(annotated); _ = try await f.repo.undo(light)
        XCTAssertEqual(try f.git(["tag"]), "")
        try f.git(["tag", "v3"])
        let removed = try await f.repo.deleteTag("v3")
        _ = try await f.repo.undo(removed)
        XCTAssertEqual(try f.git(["tag"]), "v3\n")
    }

    func testIgnorePatternsAndGitignoreAppend() async throws {
        XCTAssertEqual(GitRepository.ignorePattern(for: "build/out.log", folder: false), "/build/out.log")
        XCTAssertEqual(GitRepository.ignorePattern(for: "tmp", folder: true), "/tmp/")
        XCTAssertEqual(GitRepository.ignorePattern(for: "a[1]*.txt", folder: false), "/a\\[1\\]\\*.txt")
        let f = try ActionFixture()
        try f.initial()
        try f.write(".gitignore", "node_modules")
        try f.write("junk.log", "x")
        try await f.repo.addToGitignore("/junk.log")
        try await f.repo.addToGitignore("/junk.log")
        XCTAssertEqual(try f.read(".gitignore"), "node_modules\n/junk.log\n")
        XCTAssertEqual(try f.git(["status", "--porcelain", "--", "junk.log"]), "")
        let tracked = try await f.repo.isTracked("sample.txt")
        let untracked = try await f.repo.isTracked("junk.log")
        XCTAssertTrue(tracked); XCTAssertFalse(untracked)
    }
}

final class WorktreeStatusTests: XCTestCase {
    func testStatusCountsChangesAndOwnCommitsAndGuardsRemoval() async throws {
        let f = try ActionFixture()
        try f.initial()
        let base = f.directory.deletingLastPathComponent()
        let busy = base.appendingPathComponent("busy-tree"), done = base.appendingPathComponent("done-tree")
        let loose = base.appendingPathComponent("loose-tree")
        try f.git(["worktree", "add", "-b", "agent/busy", busy.path])
        try f.git(["worktree", "add", "--detach", done.path])
        try f.git(["worktree", "add", "--detach", loose.path])
        try "new\n".write(to: busy.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: loose.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try f.git(["-C", loose.path, "add", "x.txt"])
        try f.git(["-C", loose.path, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "only here"])

        let statuses = await f.repo.worktreeStatuses(try await f.repo.worktrees())
        func status(_ url: URL) -> WorktreeStatus? {
            statuses.first { URL(fileURLWithPath: $0.info.path).resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }
        }
        let busyStatus = try XCTUnwrap(status(busy)), doneStatus = try XCTUnwrap(status(done)), looseStatus = try XCTUnwrap(status(loose))
        XCTAssertEqual(busyStatus.changes, 1); XCTAssertTrue(busyStatus.hasWork); XCTAssertFalse(busyStatus.canRemove)
        XCTAssertEqual(doneStatus.changes, 0); XCTAssertEqual(doneStatus.ownCommits, 0); XCTAssertTrue(doneStatus.canRemove)
        XCTAssertNotNil(doneStatus.modified)
        XCTAssertEqual(looseStatus.ownCommits, 1); XCTAssertFalse(looseStatus.canRemove, "a detached commit would be left behind")
        XCTAssertFalse(statuses[0].canRemove, "the main checkout is never removed")

        try await f.repo.removeWorktree(doneStatus)
        XCTAssertFalse(FileManager.default.fileExists(atPath: done.path))
        do { try await f.repo.removeWorktree(busyStatus); XCTFail("removed a worktree with changes") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: busy.path))
    }

    func testAgentIsGuessedFromThePath() {
        XCTAssertEqual(WorktreeAgent.guess(path: "/Users/a/.codex/worktrees/1f2e/app"), .codex)
        XCTAssertEqual(WorktreeAgent.guess(path: "/repo/.claude/worktrees/fix"), .claudeCode)
        XCTAssertNil(WorktreeAgent.guess(path: "/repo-feature"))
        let status = WorktreeStatus(info: WorktreeInfo(path: "/Users/a/.codex/worktrees/1f2e/app", branch: nil, head: "abc", isMain: false),
                                    changes: 0, ownCommits: 0, modified: nil)
        XCTAssertEqual(status.folder, "1f2e/app")
    }
}
