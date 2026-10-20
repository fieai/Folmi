import AppKit
import XCTest
@testable import Folmi

@MainActor
final class MarkdownOutlineTests: XCTestCase {
    private let sample = "# 总览\n\n介绍\n\n## 安装\n\n步骤一\n\n```\n# 不是标题\n```\n\n### 细节 ##\n\n更多\n\n## 安装\n\n第二个同名\n\n# 附录\n"

    // MARK: Outline

    func testHeadingsSkipFencesAndGetStableKeys() {
        let headings = MarkdownOutline.headings(sample)
        XCTAssertEqual(headings.map(\.title), ["总览", "安装", "细节", "安装", "附录"])
        XCTAssertEqual(headings.map(\.level), [1, 2, 3, 2, 1])
        XCTAssertEqual(headings.map(\.line), [0, 4, 12, 16, 20])
        XCTAssertEqual(headings[1].key, "2|安装|0")
        XCTAssertEqual(headings[3].key, "2|安装|1", "a second identical heading gets its own key")
        XCTAssertEqual((sample as NSString).substring(with: headings[2].range), "### 细节 ##")
        XCTAssertEqual(MarkdownOutline.currentIndex(headings, at: (sample as NSString).range(of: "更多").location), 2)
        XCTAssertEqual(MarkdownOutline.currentIndex(headings, at: 0), 0)
        XCTAssertEqual(MarkdownOutline.headings("#标签不是标题\n####### 七级也不是\n").count, 0)
    }

    func testSectionsEndAtTheNextHeadingOfTheSameLevel() {
        let source = sample as NSString
        let layout = MarkdownOutline.layout(sample)
        XCTAssertEqual(source.substring(with: layout.bodies[1]!), "\n步骤一\n\n```\n# 不是标题\n```\n\n### 细节 ##\n\n更多\n\n")
        XCTAssertEqual(source.substring(with: layout.bodies[0]!).hasSuffix("第二个同名\n\n"), true, "a level 1 section holds its level 2 ones")
        XCTAssertNil(layout.bodies[4], "the last heading has nothing under it")
    }

    // MARK: Display

    private func editor(_ text: String, caret: Int) -> (EditorTextView, NSWindow) {
        let editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        editor.isRichText = false; editor.allowsUndo = true; editor.markdownEditing = true
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        editor.string = text
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        return (editor, window)
    }

    // MARK: Wiki links

    func testWikiTargetsResolveByName() {
        let line = "去 [[使用说明#快速开始|这里]] 看"
        XCTAssertEqual(MarkdownLinks.target(in: line, at: (line as NSString).range(of: "这里").location), "[[使用说明#快速开始]]")
        XCTAssertEqual(MarkdownLinks.resolve("[[使用说明#快速开始]]", from: "a.md"), .wiki(name: "使用说明", anchor: "快速开始"))
        XCTAssertEqual(MarkdownLinks.resolve("[[usage]]", from: "a.md"), .wiki(name: "usage", anchor: nil))
        let paths = ["notes/usage.md", "docs/usage.md", "deep/a/b/usage.md", "Usage.txt", "img/pic.png", "README.md"]
        XCTAssertEqual(MarkdownWiki.match("usage", from: "docs/guide.md", in: paths), "docs/usage.md", "the document's folder wins")
        XCTAssertEqual(MarkdownWiki.match("usage", from: "README.md", in: paths), "docs/usage.md", "then the shortest path")
        XCTAssertEqual(MarkdownWiki.match("a/b/usage", from: "README.md", in: paths), "deep/a/b/usage.md")
        XCTAssertEqual(MarkdownWiki.match("pic.png", from: "README.md", in: paths), "img/pic.png")
        XCTAssertEqual(MarkdownWiki.match("readme", from: "docs/x.md", in: paths), "README.md", "names ignore case")
        XCTAssertNil(MarkdownWiki.match("missing", from: "README.md", in: paths))
    }

    func testCompletionNamesAndTypedRange() {
        let paths = ["docs/usage.md", "notes/usage.md", "docs/changes.md", "README.md", "src/app.js"]
        XCTAssertEqual(MarkdownWiki.names(paths, matching: "ch"), ["changes"])
        XCTAssertEqual(Set(MarkdownWiki.names(paths, matching: "us")), ["docs/usage", "notes/usage"], "shared names use paths")
        XCTAssertEqual(MarkdownWiki.names(paths, matching: "").count, 4, "only Markdown notes")
        let text = "看 [[使用]] 和 [[a]]"
        let caret = (text as NSString).range(of: "用").location + 1
        XCTAssertEqual(MarkdownWiki.partialRange(text: text, selection: NSRange(location: caret, length: 0)),
                       (text as NSString).range(of: "使用"))
        XCTAssertNil(MarkdownWiki.partialRange(text: text, selection: NSRange(location: 1, length: 0)))
        XCTAssertNil(MarkdownWiki.partialRange(text: "[[a|b", selection: NSRange(location: 5, length: 0)), "past the pipe is shown text")
        XCTAssertEqual(MarkdownWiki.partialRange(text: "[[]]", selection: NSRange(location: 2, length: 0)), NSRange(location: 2, length: 0))
    }

    func testCreatingANoteNeverOverwritesOrLeavesTheProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = EditorWorkspace(root: root)
        XCTAssertEqual(try workspace.createWikiNote("新笔记", from: "docs/guide.md"), "docs/新笔记.md")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("docs/新笔记.md"), encoding: .utf8), "# 新笔记\n\n")
        XCTAssertThrowsError(try workspace.createWikiNote("新笔记", from: "docs/guide.md"), "an existing note is not replaced")
        XCTAssertThrowsError(try workspace.createWikiNote("../../逃出", from: "docs/guide.md"))
        XCTAssertThrowsError(try workspace.createWikiNote(".git/hooks/x", from: "a.md"))
        var asked: String?
        workspace.followWikiLink("新笔记", anchor: nil, from: "docs/guide.md") { asked = $0; return false }
        XCTAssertNil(asked, "an existing note opens without asking")
        XCTAssertEqual(workspace.selectedDocumentID, "docs/新笔记.md")
        workspace.followWikiLink("另一篇", anchor: nil, from: "docs/guide.md") { asked = $0; return false }
        XCTAssertEqual(asked, "另一篇")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/另一篇.md").path), "declined, nothing created")
    }
}
