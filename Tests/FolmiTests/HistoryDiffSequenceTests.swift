import AppKit
import SwiftUI
import XCTest
@testable import FolmiCore
@testable import Folmi

final class HistoryDiffSequenceTests: XCTestCase {
    @MainActor
    func testCompareSearchRevealsAnOffscreenHistoricalFileWithoutStaging() async throws {
        let demo = try await DemoRepository.create()
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        func git(_ arguments: [String]) async throws -> String {
            try await CommandRunner.git(arguments, at: demo.root, environment: demo.environment)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["add", "-A"])
        _ = try await git(["commit", "-qm", "Demo state"])
        let base = try await git(["rev-parse", "HEAD"])
        let first = "aa-history-first.txt", second = "zz-history-second.txt"
        try (1...300).map { "historical line \($0)\n" }.joined().write(
            to: demo.root.appendingPathComponent(first), atomically: true, encoding: .utf8)
        _ = try await git(["add", "--", first])
        _ = try await git(["commit", "-qm", "First file"])
        try "needle committed in the second file\n".write(
            to: demo.root.appendingPathComponent(second), atomically: true, encoding: .utf8)
        _ = try await git(["add", "--", second])
        _ = try await git(["commit", "-qm", "Second file"])
        let target = try await git(["rev-parse", "HEAD"])
        try "later working copy\n".write(to: demo.root.appendingPathComponent(second), atomically: true, encoding: .utf8)

        let repository = GitRepository(url: demo.root, environment: demo.environment)
        let detail = try await repository.compareDetail(base: base, target: target)
        XCTAssertEqual(detail.files.map(\.path), [first, second])
        let view = HistoryDiffSequence(repository: repository, scope: .init(commit: target, base: base),
                                       files: detail.files, selectedPath: first,
                                       sideTitles: ("起点", "终点"), unified: false, columnWidth: 450)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 470), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(400))
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f",
            charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)))
        try await eventually("历史查找获得焦点") { window.firstResponder is NSTextView }
        let field = try XCTUnwrap(window.firstResponder as? NSTextView)
        field.insertText("needle", replacementRange: NSRange(location: NSNotFound, length: 0))

        func showsHistoricalHit(_ view: NSView) -> Bool {
            if let canvas = view as? DiffRowsCanvas, let hit = canvas.searchHit,
               let row = hit.rowIndex(in: canvas.rows, unified: false) {
                return canvas.rows[row].new?.line.text == "needle committed in the second file"
                    && canvas.visibleRect.contains(NSPoint(x: 10, y: (CGFloat(row) + 0.5) * DiffCanvasMetrics.rowHeight))
                    && !canvas.canSelect
            }
            return view.subviews.contains(where: showsHistoricalHit)
        }
        try await eventually("滚动到第二个文件的历史版本") { showsHistoricalHit(host) }
        let staged = try await git(["diff", "--cached", "--name-only"])
        XCTAssertTrue(staged.isEmpty)
    }

    @MainActor
    private func eventually(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("等待超时：\(description)")
                throw FolmiFailure(message: description)
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
}
