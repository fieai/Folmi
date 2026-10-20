import AppKit
import SwiftUI
import XCTest
import FolmiCore
@testable import Folmi

final class AllChangesTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    private func diff(_ path: String, _ area: ChangeArea, hunks: Int, linesPerHunk: Int = 2) -> FileDiff {
        let hunkList = (0..<hunks).map { index in
            DiffHunk(id: "hunk-\(index)", header: "@@ -\(index * 10 + 1),1 +\(index * 10 + 1),1 @@",
                     lines: (0..<linesPerHunk).map { DiffLine(id: index * 1000 + $0, text: "x", kind: $0 % 2 == 0 ? .deletion : .addition) })
        }
        return FileDiff(file: FileChange(path: path, indexCode: area == .staged ? "M" : ".", worktreeCode: area == .working ? "M" : "."),
                        area: area, rawPatch: "", hunks: hunkList, fingerprint: path + area.rawValue, isPartialSupported: true, notice: nil)
    }

    func testStopsWalkHunksAndFoldedFilesCountOnce() {
        let diffs = [diff("a", .staged, hunks: 2), diff("b", .working, hunks: 3), diff("c", .working, hunks: 0)]
        let open = AllChangesNavigator.stops(diffs, collapsed: [])
        XCTAssertEqual(open.map(\.fileKey), ["staged:a", "staged:a", "working:b", "working:b", "working:b", "working:c"])
        XCTAssertEqual(open.last?.hunkID, nil)
        let folded = AllChangesNavigator.stops(diffs, collapsed: ["working:b"])
        XCTAssertEqual(folded.count, 4)
        XCTAssertEqual(folded[2], .init(fileKey: "working:b", hunkID: nil))
    }

    func testFileJumpsGoToFirstStopOfNeighbouringFile() {
        let stops = AllChangesNavigator.stops([diff("a", .staged, hunks: 2), diff("b", .working, hunks: 3), diff("c", .working, hunks: 1)], collapsed: [])
        XCTAssertEqual(AllChangesNavigator.nextFile(stops, from: 0, forward: true), 2)
        XCTAssertEqual(AllChangesNavigator.nextFile(stops, from: 3, forward: true), 5)
        XCTAssertEqual(AllChangesNavigator.nextFile(stops, from: 5, forward: true), 5, "stays on the last file")
        XCTAssertEqual(AllChangesNavigator.nextFile(stops, from: 4, forward: false), 0, "back to the previous file's first hunk")
        XCTAssertEqual(AllChangesNavigator.nextFile(stops, from: 1, forward: false), 0)
    }

    func testOnlyVeryLongFilesStartFolded() {
        XCTAssertFalse(AllChangesNavigator.startsFolded(diff("small", .working, hunks: 3)))
        XCTAssertTrue(AllChangesNavigator.startsFolded(diff("big", .working, hunks: 1, linesPerHunk: 2_001)))
        XCTAssertEqual(AllChangesNavigator.changedLines(diff("x", .working, hunks: 2, linesPerHunk: 3)).added, 2)
    }

    @MainActor
    func testPageListsStagedThenUnstagedAndFollowsStaging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-AllChanges-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually { !model.busy && model.snapshot != nil }
        model.showContent(.allChanges)
        try await eventually { !model.allChangesLoading && !model.allChanges.isEmpty }
        let files = try XCTUnwrap(model.snapshot?.files)
        XCTAssertEqual(model.content, .allChanges)
        XCTAssertEqual(model.allChanges.count, files.filter(\.hasStaged).count + files.filter(\.hasWorking).count)
        let areas = model.allChanges.map(\.area)
        XCTAssertEqual(areas, areas.sorted { $0 == .staged && $1 == .working }, "staged files come first")
        XCTAssertTrue(areas.contains(.staged))
        XCTAssertNil(model.allChangesNotice)

        let host = NSHostingView(rootView: AllChangesView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        func count(_ view: NSView) -> Int { (view is DiffRowsCanvas ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1) } }
        XCTAssertGreaterThan(count(host), 0, "file sections render their diff canvases")
        window.close()

        let target = try XCTUnwrap(model.allChanges.first { $0.area == .working && $0.isPartialSupported && !$0.hunks.isEmpty })
        let stagedBefore = model.allChanges.filter { $0.area == .staged }.count
        model.applyHunk(try XCTUnwrap(target.hunks.first), in: target)
        try await eventually { !model.busy && !model.allChangesLoading }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.allChanges.contains { $0.area == .staged && $0.file.path == target.file.path })
        XCTAssertGreaterThanOrEqual(model.allChanges.filter { $0.area == .staged }.count, stagedBefore)
        XCTAssertEqual(model.content, .allChanges, "staging keeps the page open")
    }

    @MainActor
    func testLineSelectionCommentsAndStagesOnlyChosenLines() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-AllChangesLines-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually { !model.busy && model.snapshot != nil }
        model.showContent(.allChanges)
        try await eventually { !model.allChangesLoading && !model.allChanges.isEmpty }

        // A hunk with at least two added lines, so staging one leaves the other unstaged.
        let target = try XCTUnwrap(model.allChanges.first { diff in
            diff.area == .working && diff.isPartialSupported && diff.hunks.contains { $0.lines.filter { $0.kind == .addition }.count >= 2 }
        })
        let hunk = try XCTUnwrap(target.hunks.first { $0.lines.filter { $0.kind == .addition }.count >= 2 })
        let added = hunk.lines.filter { $0.kind == .addition }
        let key = target.allChangesKey

        model.toggleAllChangesLine(added[0].id, in: target)
        XCTAssertEqual(model.allChangesSelection, [key: [added[0].id]], "keyed by area and path")
        XCTAssertTrue(model.selectedLines.isEmpty, "the 差异 page's selection is separate")
        XCTAssertEqual(model.allChangesSelected(in: hunk, of: target), [added[0].id])

        // Reloading an unchanged diff keeps the selection.
        await model.loadAllChanges()
        XCTAssertEqual(model.allChangesSelection[key], [added[0].id])

        model.addAllChangesComment("这一行换个名字", hunk: hunk, in: target)
        let comment = try XCTUnwrap(model.currentReviewComments.last)
        XCTAssertEqual(comment.excerpt, ["+" + added[0].text], "only the selected line is quoted")
        XCTAssertEqual(comment.area, .working)
        XCTAssertTrue(model.allChangesSelected(in: hunk, of: target).isEmpty, "commenting clears the hunk's selection")

        model.toggleAllChangesLine(added[0].id, in: target)
        model.applyAllChangesSelection(hunk, in: target)
        try await eventually { !model.busy && !model.allChangesLoading }
        XCTAssertNil(model.errorMessage)
        let staged = try XCTUnwrap(model.allChanges.first { $0.area == .staged && $0.file.path == target.file.path })
        let stagedAdded = staged.hunks.flatMap(\.lines).filter { $0.kind == .addition }.map(\.text)
        XCTAssertTrue(stagedAdded.contains(added[0].text))
        XCTAssertFalse(stagedAdded.contains(added[1].text), "the unselected line stays unstaged")
        XCTAssertNil(model.allChangesSelection[key], "a changed diff drops its old line IDs")
        XCTAssertEqual(model.content, .allChanges)
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
