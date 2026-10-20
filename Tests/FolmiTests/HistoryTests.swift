import XCTest
import FolmiCore
@testable import Folmi

final class HistoryTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    private func node(_ id: String, _ parents: [String]) -> CommitNode {
        CommitNode(id: id, parents: parents, shortID: id, author: "a", email: "e", date: Date(), refs: [], subject: id)
    }

    func testStraightHistoryStaysInOneLane() {
        let rows = CommitGraph.layout([node("c", ["b"]), node("b", ["a"]), node("a", [])])
        XCTAssertEqual(rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(rows[0].lines.map(\.half), [.lower], "a tip has no line from above")
        XCTAssertEqual(rows[1].lines.map(\.half), [.upper, .lower])
        XCTAssertEqual(rows[2].lines.map(\.half), [.upper], "the root has no line below")
        XCTAssertEqual(rows.map(\.width), [1, 1, 1])
    }

    func testMergeOpensASecondLaneThatJoinsAtTheForkPoint() {
        // m merges f2 into b1; both branches start at base.
        let rows = CommitGraph.layout([node("m", ["b1", "f2"]), node("f2", ["f1"]), node("f1", ["base"]),
                                       node("b1", ["base"]), node("base", [])])
        XCTAssertEqual(rows.map(\.lane), [0, 1, 1, 0, 0])
        XCTAssertTrue(rows[0].lines.contains(.init(from: 0, to: 1, color: rows[1].color, half: .lower)), "merge line to the side lane")
        XCTAssertTrue(rows[1].lines.contains { $0.half == .full && $0.from == 0 }, "main lane passes beside the branch")
        XCTAssertTrue(rows[3].lines.contains { $0.half == .full && $0.from == 1 }, "branch lane passes beside main")
        XCTAssertEqual(Set(rows[4].lines.filter { $0.half == .upper }.map(\.from)), [0, 1], "both lanes meet at the fork point")
        XCTAssertEqual(rows.map(\.width), [2, 2, 2, 2, 2])
        XCTAssertNotEqual(rows[0].color, rows[1].color)
    }

    func testFreedLaneIsReusedByTheNextTip() {
        // Two unrelated tips: the second starts after the first branch ended, so it reuses lane 0.
        let rows = CommitGraph.layout([node("x", []), node("y", [])])
        XCTAssertEqual(rows.map(\.lane), [0, 0])
    }

    @MainActor
    func testDemoHistoryShowsBranchesTagsMergeAndCommitDiffs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-History-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())

        let repository = GitRepository(url: demo.root, environment: demo.environment)
        let history = try await repository.history()
        XCTAssertEqual(Set(history.map(\.subject)), ["合并 feature/guide", "添加更新记录", "补充快捷键说明", "添加使用说明", "建立演示基线"])
        func commit(_ subject: String) throws -> CommitNode { try XCTUnwrap(history.first { $0.subject == subject }) }
        let merge = history[0], tip = try commit("补充快捷键说明"), base = try commit("建立演示基线"), mainSide = try commit("添加更新记录")
        XCTAssertEqual(merge.subject, "合并 feature/guide")
        XCTAssertEqual(history.last?.id, base.id, "parents come after children")
        XCTAssertTrue(merge.isMerge)
        XCTAssertTrue(merge.refs.contains("HEAD -> main"), "\(merge.refs)")
        XCTAssertTrue(tip.refs.contains("feature/guide"))
        XCTAssertTrue(base.refs.contains("tag: v0.1"))
        XCTAssertEqual(CommitGraph.layout(history).map(\.width).max(), 2)

        let mergeDetail = try await repository.commitDetail(merge.id)
        XCTAssertEqual(mergeDetail.files.map(\.path), ["docs/usage.md"], "compared with the first parent")
        XCTAssertEqual(mergeDetail.message, "合并 feature/guide")
        let root = try await repository.commitDetail(base.id)
        XCTAssertEqual(Set(root.files.map(\.path)), ["README.md", "Sources/Greeting.swift"])
        XCTAssertEqual(Set(root.files.map(\.status)), ["A"])
        let diff = try await repository.commitDiff(tip.id, file: CommitFileChange(path: "docs/usage.md", status: "M"))
        XCTAssertFalse(diff.isPartialSupported)
        XCTAssertTrue(diff.hunks.flatMap(\.lines).contains { $0.kind == .addition && $0.text.contains("切换面板") })
        do {
            _ = try await repository.commitDetail("--help")
            XCTFail("non-hex ids are refused")
        } catch {}

        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually { !model.busy && model.snapshot != nil }
        model.showContent(.history)
        try await eventually { model.commitFileDiff != nil }
        XCTAssertEqual(model.content, .history)
        XCTAssertEqual(model.selectedCommitID, merge.id, "starts at HEAD")
        XCTAssertEqual(model.selectedCommitFile, "docs/usage.md")
        model.moveCommitSelection(by: history.firstIndex { $0.id == mainSide.id }!)
        try await eventually { model.commitDetail?.id == mainSide.id && model.commitFileDiff?.file.path == "docs/changes.md" }
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
