import AppKit
import XCTest
@testable import Folmi

@MainActor
final class MarkdownImageTableTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-md-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs/img"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
    private func editor(_ text: String, caret: Int, width: CGFloat = 600) -> (EditorTextView, NSWindow) {
        let editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        editor.isRichText = false; editor.allowsUndo = true; editor.markdownEditing = true
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        editor.string = text
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        return (editor, window)
    }
    // MARK: Parsing

    func testRowSplittingAndAlignments() {
        let units = Array("a | b |c".utf16)
        let row = MarkdownTable.row(units, start: 0, end: units.count)!
        XCTAssertFalse(row.hasLeadingPipe)
        XCTAssertEqual(row.cells.map { String(decoding: units[$0.location..<NSMaxRange($0)], as: UTF16.self) }, ["a ", " b ", "c"])
        let delimiter = Array("|:--|:-:|--:|---".utf16)
        XCTAssertEqual(MarkdownTable.delimiter(delimiter, start: 0, end: delimiter.count), [.left, .center, .right, .left])
        let notDelimiter = Array("| -- | x |".utf16)
        XCTAssertNil(MarkdownTable.delimiter(notDelimiter, start: 0, end: notDelimiter.count))
        XCTAssertNil(MarkdownTable.row(Array("no pipes".utf16), start: 0, end: 8))
    }

    // MARK: Tab

    func testTabWalksCellsSkipsDelimiterAndAddsARow() throws {
        let text = "| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |\n"
        let source = text as NSString
        func apply(_ edit: EditorLineEdit, to text: String) -> String {
            (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        }
        var edit = try XCTUnwrap(MarkdownTable.tab(text: text, selection: NSRange(location: 2, length: 0), backward: false))
        XCTAssertEqual(source.substring(with: edit.selection), "数量")
        edit = try XCTUnwrap(MarkdownTable.tab(text: text, selection: edit.selection, backward: false))
        XCTAssertEqual(source.substring(with: edit.selection), "苹果", "the delimiter row is skipped")
        edit = try XCTUnwrap(MarkdownTable.tab(text: text, selection: edit.selection, backward: true))
        XCTAssertEqual(source.substring(with: edit.selection), "数量")
        let last = source.range(of: "3")
        edit = try XCTUnwrap(MarkdownTable.tab(text: text, selection: last, backward: false))
        let grown = apply(edit, to: text)
        XCTAssertEqual(grown, "| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |\n|   |   |\n")
        XCTAssertEqual(edit.selection, NSRange(location: (grown as NSString).range(of: "|   |   |").location + 2, length: 0))
        XCTAssertNil(MarkdownTable.tab(text: "普通 | 文字\n", selection: NSRange(location: 1, length: 0), backward: false), "no delimiter row, no table")
        XCTAssertNil(MarkdownTable.tab(text: text + "\n后文\n", selection: NSRange(location: source.length + 2, length: 0), backward: false))
    }

    func testInsertTableSelectsFirstHeader() {
        let edit = MarkdownTable.insert(text: "文字", selection: NSRange(location: 2, length: 0))
        let result = ("文字" as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertEqual(result, "文字\n\n| 列 1 | 列 2 |\n| --- | --- |\n|  |  |\n")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "列 1")
    }

    // MARK: Display

    func testPastedPictureIsSavedToAssetsAndLinked() throws {
        let workspace = EditorWorkspace(root: root)
        let date = Date(timeIntervalSince1970: 0)
        let link = try workspace.saveImageAsset(png(width: 4, height: 4), for: "docs/使用 说明.md", date: date)
        XCTAssertTrue(link.hasPrefix("assets/使用-说明-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/" + link).path))
        let second = try workspace.saveImageAsset(png(width: 4, height: 4), for: "docs/使用 说明.md", date: date)
        XCTAssertNotEqual(second, link, "never overwrites")
        XCTAssertTrue(second.hasSuffix("-2.png"))
        XCTAssertNotNil(workspace.imageURL(link, from: "docs/使用 说明.md"))

        try png(width: 4, height: 4).write(to: root.appendingPathComponent("docs/img/my shot.png"))
        XCTAssertEqual(try workspace.imageLink(for: root.appendingPathComponent("docs/img/my shot.png"), from: "docs/guide.md"), "img/my%20shot.png")
        XCTAssertEqual(try workspace.imageLink(for: root.appendingPathComponent("docs/img/my shot.png"), from: "notes/a/b.md"), "../../docs/img/my%20shot.png")
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).png")
        try png(width: 4, height: 4).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        let copied = try workspace.imageLink(for: external, from: "README.md")
        XCTAssertTrue(copied.hasPrefix("assets/README-"), "a file from outside is copied in")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(copied).path))

        let (editor, window) = editor("前文", caret: 2)
        defer { window.close() }
        editor.importImages = { files, data in workspace.imageMarkdown(files: files, png: data, for: "docs/guide.md") }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("folmi-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(png(width: 4, height: 4), forType: .png)
        XCTAssertTrue(editor.insertImages(from: pasteboard))
        XCTAssertTrue(editor.string.hasPrefix("前文\n![](assets/guide-"), editor.string)
        pasteboard.clearContents()
        pasteboard.setString("纯文字", forType: .string)
        XCTAssertFalse(editor.insertImages(from: pasteboard), "text pastes as text")
    }
}
