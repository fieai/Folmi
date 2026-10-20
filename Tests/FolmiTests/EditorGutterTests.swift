import XCTest
import FolmiCore
@testable import Folmi

final class EditorGutterTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    private func base(_ text: String, newline: String = "\n", bom: Bool = false) -> IndexBase {
        var data = Data(text.replacingOccurrences(of: "\n", with: newline).utf8)
        if bom { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return IndexBase(GitRepository.IndexFile(path: "a.txt", mode: "100644", object: "abc", data: data))!
    }

    func testLinesKeepNewlinesAndMissingFinalNewlineIsAChange() {
        XCTAssertEqual(GutterDiff.lines("a\nb"), ["a\n", "b"])
        XCTAssertEqual(GutterDiff.lines("a\n"), ["a\n"])
        XCTAssertEqual(GutterDiff.lines(""), [])
        XCTAssertEqual(GutterDiff.changes(base: "a\nb\n", current: "a\nb"), [LineDiff.Change(old: 1..<2, new: 1..<2)])
    }

    func testMarksClassifyAddedModifiedAndDeleted() {
        let marks = GutterDiff.Marks(GutterDiff.changes(base: "a\nb\nc\nd\n", current: "a\nB\nc\nnew\n"))
        XCTAssertEqual(marks.lineKinds[1], .modified)
        XCTAssertEqual(marks.lineKinds[3], .modified)
        let deletion = GutterDiff.Marks(GutterDiff.changes(base: "a\nb\nc\n", current: "a\nc\n"))
        XCTAssertEqual(deletion.deletionsBefore, [1])
        XCTAssertEqual(deletion.change(atLine: 1), LineDiff.Change(old: 1..<2, new: 1..<1))
        XCTAssertEqual(deletion.change(atLine: 0), LineDiff.Change(old: 1..<2, new: 1..<1), "the line above the marker also opens it")
        let added = GutterDiff.Marks(GutterDiff.changes(base: "a\n", current: "a\nx\ny\n"))
        XCTAssertEqual(added.lineKinds, [1: .added, 2: .added])
    }

    func testStageTakesOnlyOneChangeIntoTheIndex() {
        let baseText = "one\ntwo\nthree\nfour\n", current = "ONE\ntwo\nthree\nfour\nfive\n"
        let changes = GutterDiff.changes(base: baseText, current: current)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(GutterDiff.staged(base: baseText, current: current, change: changes[1]), "one\ntwo\nthree\nfour\nfive\n")
        XCTAssertEqual(GutterDiff.staged(base: baseText, current: current, change: changes[0]), "ONE\ntwo\nthree\nfour\n")
    }

    func testRevertReplacesExactlyTheChangedBufferLines() throws {
        let baseText = "one\ntwo\nthree\n", current = "one\n二号\n新增\nthree\n"
        let change = try XCTUnwrap(GutterDiff.changes(base: baseText, current: current).first)
        let edit = try XCTUnwrap(GutterDiff.revert(base: baseText, current: current, change: change))
        XCTAssertEqual((current as NSString).replacingCharacters(in: edit.range, with: edit.replacement), baseText)
        let deletion = try XCTUnwrap(GutterDiff.changes(base: baseText, current: "one\nthree\n").first)
        let restore = try XCTUnwrap(GutterDiff.revert(base: baseText, current: "one\nthree\n", change: deletion))
        XCTAssertEqual(("one\nthree\n" as NSString).replacingCharacters(in: restore.range, with: restore.replacement), baseText)
    }

    func testIndexBaseNormalizesLikeTheEditorAndEncodesBack() {
        let crlf = base("a\nb\n", newline: "\r\n", bom: true)
        XCTAssertEqual(crlf.text, "a\nb\n")
        XCTAssertEqual(crlf.encoded("a\nx\nb\n"), Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nx\r\nb\r\n".utf8))
        XCTAssertFalse(crlf.mixedNewlines)
        let mixed = IndexBase(GitRepository.IndexFile(path: "m", mode: "100644", object: "o", data: Data("a\r\nb\n".utf8)))
        XCTAssertEqual(mixed?.mixedNewlines, true)
        XCTAssertNil(IndexBase(GitRepository.IndexFile(path: "bin", mode: "100644", object: "o", data: Data([0, 1, 2]))))
    }

    @MainActor
    func testStagingAnUnsavedEditorChangeWritesOnlyTheIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Gutter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually { !model.busy && model.snapshot != nil }
        let editor = try XCTUnwrap(model.editorWorkspace)
        try editor.open(path: "README.md")
        let disk = try String(contentsOf: demo.root.appendingPathComponent("README.md"), encoding: .utf8)
        let loader = try XCTUnwrap(editor.loadIndexBase)
        let indexBase = await loader("README.md")
        let base = try XCTUnwrap(indexBase)
        let current = base.text + "来自编辑器的未保存行\n"
        editor.updateText(id: "README.md", text: current)
        let change = try XCTUnwrap(GutterDiff.changes(base: base.text, current: current).last)
        let revision = editor.indexRevision

        model.stageEditorChange(base: base, data: base.encoded(GutterDiff.staged(base: base.text, current: current, change: change)))
        try await eventually { !model.busy }
        XCTAssertNil(model.errorMessage)
        let staged = await loader("README.md")
        XCTAssertEqual(staged?.text, base.text + "来自编辑器的未保存行\n")
        XCTAssertEqual(try String(contentsOf: demo.root.appendingPathComponent("README.md"), encoding: .utf8), disk, "the file on disk is not saved")
        XCTAssertNotEqual(editor.indexRevision, revision, "open editors are told to reload their gutter base")

        model.stageEditorChange(base: base, data: Data("stale\n".utf8))
        try await eventually { !model.busy }
        XCTAssertNotNil(model.errorMessage, "an outdated gutter base is refused")
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 8, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
