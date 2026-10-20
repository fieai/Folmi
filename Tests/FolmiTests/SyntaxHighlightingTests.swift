import XCTest
import AppKit
@testable import Folmi

final class SyntaxHighlightingTests: XCTestCase {
    func testLanguageDetectionAndUnknownFilesStayPlain() throws {
        for path in ["src/a.js", "a.jsx", "a.MJS", "a.cjs"] { XCTAssertEqual(SyntaxLanguage(path: path), .javascript) }
        for path in ["src/a.ts", "a.tsx", "a.mts", "a.cts"] { XCTAssertEqual(SyntaxLanguage(path: path), .typescript) }
        for path in ["a.py", "a.pyi", "a.pyw"] { XCTAssertEqual(SyntaxLanguage(path: path), .python) }
        XCTAssertEqual(SyntaxLanguage(path: "source.swift"), .swift)
        XCTAssertEqual(SyntaxLanguage(path: "data.json"), .json)
        XCTAssertEqual(SyntaxLanguage(path: "run.zsh"), .shell)
        XCTAssertEqual(SyntaxLanguage(path: "notes.unknown"), .plainText)
        let result = try XCTUnwrap(SyntaxTokenizer.tokenize("class 12 // comment", language: .plainText))
        XCTAssertTrue(result.tokens.isEmpty)
        XCTAssertFalse(result.isLimited)
    }

    func testJavaScriptMultilineCommentsAndTemplateStringsOwnTheirContents() throws {
        let text = "const icon = `你好👩🏽‍💻 ${return 42}\n// still string`; /* let 12\nreturn 'x' */\n// const 7\nlet value = 1.25e-3;"
        let result = try result(text, .javascript)
        XCTAssertEqual(contents(of: .keyword, in: result, text: text), ["const", "let"])
        XCTAssertEqual(contents(of: .number, in: result, text: text), ["1.25e-3"])
        XCTAssertEqual(contents(of: .string, in: result, text: text), ["`你好👩🏽‍💻 ${return 42}\n// still string`"])
        XCTAssertEqual(contents(of: .comment, in: result, text: text), ["/* let 12\nreturn 'x' */", "// const 7"])
        assertValidNonOverlappingRanges(result, in: text)
    }

    func testPythonTripleQuotedAndPrefixedStringsAndComments() throws {
        let text = "def 你好():\n    text = rf\"\"\"class 12 # not comment\nreturn 😀\"\"\"\n    other = '''async\n42''' # return 9\n    return True\n"
        let result = try result(text, .python)
        XCTAssertEqual(contents(of: .keyword, in: result, text: text), ["def", "return"])
        XCTAssertTrue(contents(of: .number, in: result, text: text).isEmpty)
        XCTAssertEqual(contents(of: .string, in: result, text: text), ["rf\"\"\"class 12 # not comment\nreturn 😀\"\"\"", "'''async\n42'''"])
        XCTAssertEqual(contents(of: .comment, in: result, text: text), ["# return 9"])
        XCTAssertEqual(contents(of: .literal, in: result, text: text), ["True"])
        assertValidNonOverlappingRanges(result, in: text)
    }

    func testEscapedQuotesUnterminatedStringsAndUnicodeRanges() throws {
        let text = "const 中文😀 = \"hello \\\"return\\\" 👩🏽‍💻\"; // 🥳\nlet tail = 'unfinished"
        let result = try result(text, .javascript)
        XCTAssertEqual(contents(of: .keyword, in: result, text: text), ["const", "let"])
        XCTAssertEqual(contents(of: .string, in: result, text: text), ["\"hello \\\"return\\\" 👩🏽‍💻\"", "'unfinished"])
        XCTAssertEqual(contents(of: .comment, in: result, text: text), ["// 🥳"])
        assertValidNonOverlappingRanges(result, in: text)
    }

    func testSwiftNestedCommentsJSONAndShell() throws {
        let swift = "/* let /* true */ 10 */\nlet count: Int = 3"
        let swiftResult = try result(swift, .swift)
        XCTAssertEqual(contents(of: .keyword, in: swiftResult, text: swift), ["let"])
        XCTAssertEqual(contents(of: .comment, in: swiftResult, text: swift), ["/* let /* true */ 10 */"])
        let json = "{\"const\": true, \"value\": 3.14, \"nothing\": null}"
        let jsonResult = try result(json, .json)
        XCTAssertTrue(contents(of: .keyword, in: jsonResult, text: json).isEmpty)
        XCTAssertEqual(contents(of: .literal, in: jsonResult, text: json), ["true", "null"])
        let shell = "if true; then echo $VALUE ${PATH}; fi # if 12"
        let shellResult = try result(shell, .shell)
        XCTAssertEqual(contents(of: .keyword, in: shellResult, text: shell), ["if", "then", "fi"])
        XCTAssertEqual(contents(of: .variable, in: shellResult, text: shell), ["$VALUE", "${PATH}"])
    }

    func testLargeInputIsBoundedAndDoesNotSplitSurrogatePair() throws {
        let text = "\"" + String(repeating: "a", count: SyntaxTokenizer.maximumUTF16Count - 2) + "😀 rest\""
        let result = try result(text, .javascript)
        XCTAssertTrue(result.isLimited)
        XCTAssertLessThanOrEqual(result.scannedUTF16Count, SyntaxTokenizer.maximumUTF16Count)
        assertValidNonOverlappingRanges(result, in: text)
        let source = Array(text.utf16)
        if result.scannedUTF16Count > 0 {
            XCTAssertFalse((0xD800...0xDBFF).contains(source[result.scannedUTF16Count - 1]))
        }
        let manyTokens = String(repeating: "let x = 1; ", count: 20_000)
        let tokenLimited = try XCTUnwrap(SyntaxTokenizer.tokenize(manyTokens, language: .javascript, maximumTokens: 30))
        XCTAssertTrue(tokenLimited.isLimited)
        XCTAssertEqual(tokenLimited.tokens.count, 30)
        XCTAssertLessThan(tokenLimited.scannedUTF16Count, manyTokens.utf16.count)
    }

    func testCancellationDiscardsResults() {
        XCTAssertNil(SyntaxTokenizer.tokenize(String(repeating: "// hello\n", count: 100_000), language: .javascript, isCancelled: { true }))
        var checks = 0
        let result = SyntaxTokenizer.tokenize("/*" + String(repeating: "a", count: 100_000), language: .javascript, isCancelled: {
            checks += 1
            return checks > 3
        })
        XCTAssertNil(result)
        XCTAssertGreaterThan(checks, 3)
    }

    @MainActor
    func testApplyingAndReapplyingPreservesTextSelectionsUndoAndChangeNotifications() throws {
        let editor = HighlightTestTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let observer = HighlightChangeObserver()
        editor.delegate = observer
        editor.isRichText = false
        editor.allowsUndo = true
        let text = "const 你好 = 12; // 😀\n"
        editor.string = text
        editor.selectedRanges = [NSValue(range: NSRange(location: 6, length: 2))]
        editor.testUndoManager.registerUndo(withTarget: observer) { target in target.undoCalls += 1 }
        editor.testUndoManager.setActionName("Existing text edit")
        let actionBefore = editor.testUndoManager.undoActionName
        let selectionBefore = editor.selectedRanges
        let countBefore = observer.changeCount
        SyntaxHighlightApplier.apply(try result(text, .javascript), to: editor)
        SyntaxHighlightApplier.apply(try result(text, .python), to: editor)
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(editor.selectedRanges, selectionBefore)
        XCTAssertEqual(observer.changeCount, countBefore)
        XCTAssertEqual(editor.testUndoManager.undoActionName, actionBefore)
        XCTAssertTrue(editor.testUndoManager.canUndo)
        editor.testUndoManager.undo()
        XCTAssertEqual(observer.undoCalls, 1)
        XCTAssertFalse(editor.testUndoManager.canUndo)
        XCTAssertEqual(editor.string, text)
    }

    @MainActor
    func testAsynchronousEditRehighlightsNewestTextAndPlainTextClearsColors() async throws {
        let editor = HighlightTestTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        editor.string = "const stale = 42"
        let highlighter = EditorSyntaxHighlighter()
        highlighter.editor = editor
        highlighter.schedule(language: .javascript)
        editor.string = "def current():\n    return True"
        editor.setSelectedRange(NSRange(location: 5, length: 2))
        let selection = editor.selectedRanges
        let highlighted = expectation(description: "latest Python highlight")
        highlighter.onStatus = { if $0 == "词法高亮" { highlighted.fulfill() } }
        highlighter.schedule(language: .python, immediately: true)
        await fulfillment(of: [highlighted], timeout: 3)
        XCTAssertEqual(editor.string, "def current():\n    return True")
        XCTAssertEqual(editor.selectedRanges, selection)
        XCTAssertEqual(editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, SyntaxHighlightApplier.color(for: .keyword))
        let plain = expectation(description: "plain text")
        highlighter.onStatus = { if $0 == "无高亮" { plain.fulfill() } }
        highlighter.schedule(language: .plainText, immediately: true)
        await fulfillment(of: [plain], timeout: 3)
        XCTAssertEqual(editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.textColor)
        highlighter.cancel()
    }

    @MainActor
    func testMarkedTextSkipsAttributeApplication() throws {
        let editor = HighlightTestTextView(frame: .zero)
        editor.string = "const 中文 = 1"
        editor.composing = true
        let before = editor.attributedString()
        SyntaxHighlightApplier.apply(try result(editor.string, .javascript), to: editor)
        XCTAssertEqual(editor.attributedString(), before)
        XCTAssertEqual(editor.string, "const 中文 = 1")
    }

    private func result(_ text: String, _ language: SyntaxLanguage) throws -> SyntaxHighlightResult {
        try XCTUnwrap(SyntaxTokenizer.tokenize(text, language: language))
    }
    private func contents(of kind: SyntaxTokenKind, in result: SyntaxHighlightResult, text: String) -> [String] {
        result.tokens.filter { $0.kind == kind }.map { (text as NSString).substring(with: $0.range) }
    }
    private func assertValidNonOverlappingRanges(_ result: SyntaxHighlightResult, in text: String, file: StaticString = #filePath, line: UInt = #line) {
        var previousEnd = 0
        for token in result.tokens {
            XCTAssertGreaterThanOrEqual(token.range.location, previousEnd, file: file, line: line)
            XCTAssertGreaterThan(token.range.length, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), text.utf16.count, file: file, line: line)
            // Foundation can round-trip every token without replacing split surrogate halves.
            let substring = (text as NSString).substring(with: token.range)
            XCTAssertEqual(substring.utf16.count, token.range.length, file: file, line: line)
            previousEnd = NSMaxRange(token.range)
        }
    }
}

@MainActor
private final class HighlightTestTextView: NSTextView {
    let testUndoManager = UndoManager()
    var composing = false
    override var undoManager: UndoManager? { testUndoManager }
    override func hasMarkedText() -> Bool { composing }
}

@MainActor
private final class HighlightChangeObserver: NSObject, NSTextViewDelegate {
    var changeCount = 0
    var undoCalls = 0
    func textDidChange(_ notification: Notification) { changeCount += 1 }
}
