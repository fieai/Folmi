import AppKit
import SwiftUI
import XCTest
@testable import Folmi

/// ⌘K as the user sees it: the rows on screen must be the results Return would run.
final class PaletteViewTests: XCTestCase {
    @MainActor
    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews { if let found = field(in: subview) { return found } }
        return nil
    }
    @MainActor
    func testRowsFollowTheQueryAndReturnRunsTheShownRow() throws {
        let items = ["refresh", "large-repo", "stash", "pull"].map { id in
            PaletteItem(id: "command:" + id, kind: .command, title: ["refresh": "刷新", "large-repo": "打开大仓库模式（读取状态更快）",
                                                                        "stash": "临时收起全部改动", "pull": "从远端拉取…"][id]!,
                        subtitle: "", action: .command(id))
        }
        var usage = PaletteUsage(); usage.note("command:refresh"); usage.note("command:refresh")
        var picked: PaletteItem?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: CommandPaletteSheet(items: items, usage: usage) { picked = $0 })
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        spin(0.5)
        let input = try XCTUnwrap(field(in: hosting))
        window.makeFirstResponder(input)
        spin(0.2)
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        // ">" then a pinyin composition committed as 大仓库, like typing with an input method.
        editor.insertText(">", replacementRange: NSRange(location: NSNotFound, length: 0)); spin(0.3)
        editor.setMarkedText("da", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)); spin(0.3)
        editor.insertText("大仓库", replacementRange: NSRange(location: NSNotFound, length: 0)); spin(0.5)
        let shown = try ScreenText.read(hosting)
        XCTAssertTrue(shown.contains("大仓库模式"), "shown: \(shown)")
        XCTAssertFalse(shown.contains("刷新"), "a row left over from an earlier query: \(shown)")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:))); spin(0.3)
        XCTAssertEqual(picked?.id, "command:large-repo")
    }
}
