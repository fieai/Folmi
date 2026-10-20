import Darwin
import XCTest
@testable import Folmi

final class QuickOpenMatcherTests: XCTestCase {
    func testFilenameRanksAheadOfDirectoryAndFuzzyMatches() {
        let paths = ["main/archive.txt", "src/m-a-i-n.swift", "src/domain.swift", "src/main.swift", "main.swift"]
        let results = QuickOpenMatcher.matches(paths: paths, query: "main")
        XCTAssertEqual(results.first?.path, "main.swift")
        let index = Dictionary(uniqueKeysWithValues: results.enumerated().map { ($0.element.path, $0.offset) })
        XCTAssertLessThan(index["src/main.swift"]!, index["main/archive.txt"]!)
        XCTAssertLessThan(index["main/archive.txt"]!, index["src/m-a-i-n.swift"]!)
    }

    func testFuzzyPathAndFilenameMatchCaseInsensitively() {
        XCTAssertEqual(QuickOpenMatcher.matches(paths: ["Sources/Editor/EditorDocument.swift"], query: "edocsw").map(\.path),
                       ["Sources/Editor/EditorDocument.swift"])
        XCTAssertEqual(QuickOpenMatcher.matches(paths: ["Sources/Editor/EditorDocument.swift"], query: "s/ed/doc").map(\.path),
                       ["Sources/Editor/EditorDocument.swift"])
        XCTAssertEqual(QuickOpenMatcher.matches(paths: ["README.md"], query: "readme").count, 1)
        XCTAssertEqual(QuickOpenMatcher.matches(paths: ["café.py"], query: "cafe").count, 1)
        XCTAssertTrue(QuickOpenMatcher.matches(paths: ["src/main.py"], query: "zzzz").isEmpty)
    }

    func testEmptyQueryKeepsRecentOrderAndDeduplicatesBeforeLimit() {
        let matches = QuickOpenMatcher.matches(paths: ["z.txt", "z.txt", "a.txt", "b.txt"], query: "", limit: 2)
        XCTAssertEqual(matches.map(\.path), ["z.txt", "a.txt"])
        XCTAssertTrue(QuickOpenMatcher.matches(paths: ["one"], query: "", limit: 0).isEmpty)
        XCTAssertTrue(QuickOpenMatcher.matches(paths: ["one"], query: "", limit: -1).isEmpty)
    }

    func testLineAndColumnSuffixesAreNotPartOfTheFilenameQuery() {
        let match = QuickOpenMatcher.matches(paths: ["src/main.py"], query: "main.py:12:3").first
        XCTAssertEqual(match?.path, "src/main.py")
        XCTAssertEqual(match?.line, 12)
        XCTAssertEqual(match?.column, 3)
        let line = QuickOpenMatcher.matches(paths: ["src/main.py"], query: "main.py:12").first
        XCTAssertEqual(line?.line, 12)
        XCTAssertNil(line?.column)
        XCTAssertEqual(QuickOpenMatcher.matches(paths: ["one"], query: ":9").first?.line, 9)
        XCTAssertEqual(QuickOpenMatcher.matches(paths: ["with:colon.py"], query: "with:colon.py:9:2").first?.line, 9)
    }

    func testInvalidAndOverflowingSuffixesStayLiteral() {
        XCTAssertNil(QuickOpenMatcher.matches(paths: ["main.py"], query: "main.py:0").first)
        XCTAssertNil(QuickOpenMatcher.matches(paths: ["main.py"], query: "main.py:-1").first)
        XCTAssertNil(QuickOpenMatcher.matches(paths: ["main.py"], query: "main.py:9999999999999999999999999").first)
        XCTAssertEqual(QuickOpenMatcher.matches(paths: ["file:0"], query: "file:0").first?.path, "file:0")
    }

    func testUnsafeMetadataPathsAreNeverOffered() {
        let paths = ["/abs.py", "../escape.py", "dir/../escape.py", "dir//bad.py", "dir/./bad.py", ".git/config", "nested/.GIT/config",
                     "bad\0name", "src/main.py", ".gitignore", ".github/build.yml"]
        XCTAssertEqual(QuickOpenMatcher.matches(paths: paths, query: "").map(\.path),
                       ["src/main.py", ".gitignore", ".github/build.yml"])
    }

    func testWhitespaceChineseAndSpecialFilenamePathsArePreserved() {
        let paths = ["中文目录/脚本 🐍.py", "folder with spaces/line\nbreak.js", "-leading-name.txt"]
        XCTAssertEqual(QuickOpenMatcher.matches(paths: paths, query: "脚本").first?.path, paths[0])
        XCTAssertEqual(QuickOpenMatcher.matches(paths: paths, query: "folder spaces").first?.path, paths[1])
        XCTAssertEqual(QuickOpenMatcher.matches(paths: paths, query: "-leading").first?.path, paths[2])
    }

    func testEquivalentScoresUseStableNaturalPathOrdering() {
        let paths = ["file12.txt", "file11.txt", "file10.txt"]
        XCTAssertEqual(QuickOpenMatcher.matches(paths: paths, query: "file").map(\.path),
                       ["file10.txt", "file11.txt", "file12.txt"])
        XCTAssertEqual(QuickOpenMatcher.matches(paths: Array(paths.reversed()), query: "file"),
                       QuickOpenMatcher.matches(paths: paths, query: "file"))
    }
}

final class ProjectTextSearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-search-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testLiteralAndCaseSensitiveSearch() throws {
        try write("src/test.py", text: "Hello HELLO hello\na+b a.b [abc] (thing)\n")
        let insensitive = try ProjectTextSearch.search(root: root, paths: ["src/test.py"], query: "hello")
        XCTAssertEqual(insensitive.hits.count, 3)
        XCTAssertEqual(insensitive.hits.map(\.column), [1, 7, 13])
        XCTAssertEqual(insensitive.scannedFiles, 1)
        XCTAssertFalse(insensitive.isTruncated)
        XCTAssertNil(insensitive.notice)
        XCTAssertEqual(try ProjectTextSearch.search(root: root, paths: ["src/test.py"], query: "hello", caseSensitive: true).hits.count, 1)
        XCTAssertEqual(try ProjectTextSearch.search(root: root, paths: ["src/test.py"], query: "a.b").hits.count, 1)
        XCTAssertEqual(try ProjectTextSearch.search(root: root, paths: ["src/test.py"], query: "[abc]").hits.count, 1)
    }

    func testUTF16RangesAndCRLFPositionsPointIntoOriginalText() throws {
        let text = "😀中文 needle\r\nsecond 🐍needle\rthird needle\nfourth needle"
        try write("中文/脚本 🐍.py", text: text)
        let result = try ProjectTextSearch.search(root: root, paths: ["中文/脚本 🐍.py"], query: "needle")
        XCTAssertEqual(result.hits.map(\.line), [1, 2, 3, 4])
        XCTAssertEqual(result.hits.map(\.column), [6, 10, 7, 8])
        for hit in result.hits {
            XCTAssertEqual((text as NSString).substring(with: hit.range), "needle")
            XCTAssertFalse(hit.preview.contains("\r"))
            XCTAssertFalse(hit.preview.contains("\n"))
            XCTAssertEqual(hit.id, "\(hit.path):\(hit.range.location):6")
        }
    }

    func testUnicodeCaseMatchRetainsOriginalRange() throws {
        let text = "CAFÉ café Cafe\nÄpfel äpfel"
        try write("unicode.txt", text: text)
        let matches = try ProjectTextSearch.search(root: root, paths: ["unicode.txt"], query: "café").hits
        XCTAssertEqual(matches.map { (text as NSString).substring(with: $0.range) }, ["CAFÉ", "café"])
        XCTAssertEqual(try ProjectTextSearch.search(root: root, paths: ["unicode.txt"], query: "äpfel").hits.count, 2)
    }

    func testBOMCRLFUnicodeCoordinatesJumpIntoNormalizedEditorText() throws {
        let raw = "\u{FEFF}😀 needle\r\n中文 needle"
        try write("bom.py", text: raw)
        let hits = try ProjectTextSearch.search(root: root, paths: ["bom.py"], query: "needle").hits
        XCTAssertEqual(hits.map(\.line), [1, 2])
        XCTAssertEqual(hits.map(\.column), [4, 4])
        XCTAssertEqual(hits.map(\.range), [NSRange(location: 4, length: 6), NSRange(location: 15, length: 6)])
        let normalized = String(raw.dropFirst()).replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        for hit in hits {
            let normalizedOffset = lines.prefix(hit.line - 1).reduce(0) { $0 + ($1 as NSString).length + 1 } + hit.column - 1
            XCTAssertEqual((normalized as NSString).substring(with: NSRange(location: normalizedOffset, length: hit.range.length)), "needle")
            XCTAssertEqual((raw as NSString).substring(with: hit.range), "needle")
        }
    }

    func testOpenDocumentsReplaceDiskTextAndReturnCurrentEditorCoordinates() throws {
        try write("script.py", text: "old needle\r\nold")
        let current = "🐍 unsaved\nneedle current"
        let result = try ProjectTextSearch.search(root: root, paths: ["script.py"], query: "needle",
                                                 openDocuments: ["script.py": current])
        let hit = try XCTUnwrap(result.hits.first)
        XCTAssertEqual(hit.line, 2)
        XCTAssertEqual(hit.column, 1)
        XCTAssertEqual(hit.range, NSRange(location: 11, length: 6))
        XCTAssertEqual((current as NSString).substring(with: hit.range), "needle")
        XCTAssertEqual(hit.preview, "needle current")
        XCTAssertEqual(result.scannedFiles, 1)
        XCTAssertTrue(try XCTUnwrap(result.notice).contains("含打开文档的当前内容"))
        XCTAssertTrue(try ProjectTextSearch.search(root: root, paths: ["script.py"], query: "old",
                                                  openDocuments: ["script.py": current]).hits.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("script.py"), encoding: .utf8), "old needle\r\nold")
    }

    func testSafeOpenDocumentsNotInTreeAreIncludedWithoutReadingDiskAndUnsafeKeysAreExcluded() throws {
        let overlays = ["removed/from-disk.py": "needle draft", ".git/config": "needle protected",
                        "nested/.GIT/config": "needle protected", "../outside": "needle outside",
                        "/absolute": "needle outside", "folder//invalid": "needle invalid", "nul\0file": "needle invalid"]
        let result = try ProjectTextSearch.search(root: root, paths: [], query: "needle", openDocuments: overlays)
        XCTAssertEqual(result.hits.map(\.path), ["removed/from-disk.py"])
        XCTAssertEqual(result.scannedFiles, 1)
        XCTAssertNotNil(result.notice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("removed").path))
    }

    func testOpenDocumentBytesCountTowardSameSizeAndTotalBudgetsAsDiskFiles() throws {
        try write("disk", text: "needle")
        let result = try ProjectTextSearch.search(root: root, paths: ["large", "first", "second", "disk"], query: "needle",
                                                 limits: limits(fileBytes: 20, totalBytes: 6),
                                                 openDocuments: ["large": String(repeating: "needle", count: 5), "first": "needle", "second": "needle"])
        XCTAssertEqual(result.hits.map(\.path), ["first"])
        XCTAssertEqual(result.scannedFiles, 1)
        XCTAssertTrue(result.isTruncated)
        XCTAssertTrue(try XCTUnwrap(result.notice).contains("预算"))
        XCTAssertTrue(try XCTUnwrap(result.notice).contains("20 B"))
        let utf8 = try ProjectTextSearch.search(root: root, paths: ["emoji"], query: "😀", limits: limits(fileBytes: 7),
                                               openDocuments: ["emoji": "😀😀"])
        XCTAssertEqual(utf8.hits, [])
        XCTAssertEqual(utf8.scannedFiles, 0)
        XCTAssertTrue(try XCTUnwrap(utf8.notice).contains("7 B"))
    }

    func testOpenDocumentNULAndCancellationAreStillRejected() throws {
        let nul = try ProjectTextSearch.search(root: root, paths: [], query: "needle", openDocuments: ["invalid.txt": "needle\0text"])
        XCTAssertEqual(nul.hits, [])
        XCTAssertTrue(try XCTUnwrap(nul.notice).contains("二进制"))
        var checks = 0
        XCTAssertThrowsError(try ProjectTextSearch.search(root: root, paths: [], query: "needle",
                                                         openDocuments: ["draft.txt": String(repeating: "needle ", count: 100)],
                                                         isCancelled: { checks += 1; return checks > 4 })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testMultilineLiteralSearchStillReportsStartingLineAndOriginalRange() throws {
        let text = "begin\nneedle\r\nnext\nfinish"
        try write("multi.txt", text: text)
        let hit = try XCTUnwrap(ProjectTextSearch.search(root: root, paths: ["multi.txt"], query: "needle\r\nnext").hits.first)
        XCTAssertEqual(hit.line, 2)
        XCTAssertEqual(hit.column, 1)
        XCTAssertEqual((text as NSString).substring(with: hit.range), "needle\r\nnext")
        XCTAssertEqual(hit.preview, "needle")
    }

    func testOnlyProvidedFilePathsAreSearchedAndDuplicatesAreReadOnce() throws {
        try write("included.txt", text: "needle")
        try write("not-provided.txt", text: "needle")
        let result = try ProjectTextSearch.search(root: root, paths: ["included.txt", "included.txt"], query: "needle")
        XCTAssertEqual(result.hits.map(\.path), ["included.txt"])
        XCTAssertEqual(result.scannedFiles, 1)
    }

    func testTraversalAndGitComponentsAreExcludedBeforeOpening() throws {
        try write(".git/config", text: "needle")
        try write("nested/.GIT/config", text: "needle")
        try write("safe.py", text: "needle")
        try write(".gitignore", text: "needle")
        let result = try ProjectTextSearch.search(root: root,
                                                 paths: [".git/config", "nested/.GIT/config", "../safe.py", root.appendingPathComponent("safe.py").path,
                                                         "nested/../safe.py", "./safe.py", "safe.py", ".gitignore", "bad\0name"],
                                                 query: "needle")
        XCTAssertEqual(result.hits.map(\.path), ["safe.py", ".gitignore"])
        XCTAssertEqual(result.scannedFiles, 2)
    }

    func testRejectsRootSymlinkMissingRootFileRootAndMetadataRoot() throws {
        try write(".git/config", text: "needle")
        try write("safe.txt", text: "needle")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root)
        for path in ["alias", "missing", "safe.txt", ".git"] {
            XCTAssertThrowsError(try ProjectTextSearch.search(root: root.appendingPathComponent(path), paths: ["safe.txt"], query: "needle"))
        }
        XCTAssertThrowsError(try ProjectTextSearch.search(root: URL(string: "https://example.invalid")!, paths: [], query: "needle"))
    }

    func testDoesNotFollowFileOrDirectorySymlinksOrReadSpecialFiles() throws {
        try write("src/real.txt", text: "needle")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file-link"), withDestinationURL: root.appendingPathComponent("src/real.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dir-link"), withDestinationURL: root.appendingPathComponent("src"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside-link"), withDestinationURL: root.deletingLastPathComponent())
        let fifo = root.appendingPathComponent("pipe").path
        XCTAssertEqual(fifo.withCString { mkfifo($0, 0o600) }, 0)
        let result = try ProjectTextSearch.search(root: root, paths: ["file-link", "dir-link/real.txt", "outside-link/whatever", "pipe", "src", "src/real.txt"], query: "needle")
        XCTAssertEqual(result.hits.map(\.path), ["src/real.txt"])
        XCTAssertEqual(result.scannedFiles, 1)
        XCTAssertNotNil(result.notice)
    }

    func testBinaryNULAndInvalidUTF8AreSkippedWithNotice() throws {
        try write("binary", bytes: Data([110, 101, 101, 100, 108, 101, 0, 1]))
        try write("invalid", bytes: Data([255, 254, 110, 101, 101, 100, 108, 101]))
        try write("valid", text: "needle")
        let result = try ProjectTextSearch.search(root: root, paths: ["binary", "invalid", "valid"], query: "needle")
        XCTAssertEqual(result.hits.map(\.path), ["valid"])
        XCTAssertEqual(result.scannedFiles, 3)
        XCTAssertTrue(try XCTUnwrap(result.notice).contains("二进制"))
        XCTAssertFalse(result.isTruncated)
    }

    func testSizeLimitAndTotalBudgetAreEnforcedBeforeReading() throws {
        try write("large", text: String(repeating: "needle", count: 4))
        try write("first", text: "needle")
        try write("second", text: "needle")
        try write("empty", text: "")
        let result = try ProjectTextSearch.search(root: root, paths: ["large", "first", "second", "empty"], query: "needle",
                                                 limits: limits(fileBytes: 20, totalBytes: 6))
        XCTAssertEqual(result.hits.map(\.path), ["first"])
        XCTAssertEqual(result.scannedFiles, 2)
        XCTAssertTrue(result.isTruncated)
        XCTAssertTrue(try XCTUnwrap(result.notice).contains("预算"))
        XCTAssertTrue(try XCTUnwrap(result.notice).contains("20 B"))
    }

    func testFileCountLimitIsVisible() throws {
        for index in 0..<4 { try write("f\(index)", text: "needle") }
        let result = try ProjectTextSearch.search(root: root, paths: (0..<4).map { "f\($0)" }, query: "needle", limits: limits(files: 2))
        XCTAssertEqual(result.scannedFiles, 2)
        XCTAssertEqual(result.hits.count, 2)
        XCTAssertTrue(result.isTruncated)
        XCTAssertTrue(try XCTUnwrap(result.notice).contains("2 个文件"))
    }

    func testGlobalAndPerFileHitLimitsAreVisibleAndSearchContinuesInOtherFiles() throws {
        try write("first", text: "x x x x x")
        try write("second", text: "x x x x x")
        let perFile = try ProjectTextSearch.search(root: root, paths: ["first", "second"], query: "x", limits: limits(hitsPerFile: 2))
        XCTAssertEqual(perFile.hits.map(\.path), ["first", "first", "second", "second"])
        XCTAssertTrue(perFile.isTruncated)
        XCTAssertTrue(try XCTUnwrap(perFile.notice).contains("每个文件"))
        let total = try ProjectTextSearch.search(root: root, paths: ["first", "second"], query: "x", limits: limits(hits: 3))
        XCTAssertEqual(total.hits.count, 3)
        XCTAssertTrue(total.isTruncated)
        XCTAssertTrue(try XCTUnwrap(total.notice).contains("3 处命中"))
        let exact = try ProjectTextSearch.search(root: root, paths: ["first"], query: "x", limits: limits(hits: 5, hitsPerFile: 5))
        XCTAssertEqual(exact.hits.count, 5)
        XCTAssertFalse(exact.isTruncated)
    }

    func testDefaultLimitsAreSmallAndExplicit() {
        XCTAssertEqual(ProjectTextSearch.Limits.default.maximumFileBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(ProjectTextSearch.Limits.default.maximumTotalBytes, 64 * 1_024 * 1_024)
        XCTAssertEqual(ProjectTextSearch.Limits.default.maximumFiles, 10_000)
        XCTAssertEqual(ProjectTextSearch.Limits.default.maximumHits, 1_000)
        XCTAssertEqual(ProjectTextSearch.Limits.default.maximumHitsPerFile, 200)
    }

    func testVeryLongLinePreviewIsBoundedWithoutLosingMatchPosition() throws {
        let text = String(repeating: "😀", count: 20_000) + "needle" + String(repeating: "z", count: 100_000)
        try write("long.txt", text: text)
        let result = try ProjectTextSearch.search(root: root, paths: ["long.txt"], query: "needle")
        let hit = try XCTUnwrap(result.hits.first)
        XCTAssertEqual(hit.range, NSRange(location: 40_000, length: 6))
        XCTAssertEqual(hit.column, 40_001)
        XCTAssertEqual(hit.line, 1)
        XCTAssertLessThanOrEqual(hit.preview.count, 200)
        XCTAssertTrue(hit.preview.contains("needle"))
        XCTAssertTrue(hit.preview.hasPrefix("…"))
        XCTAssertTrue(hit.preview.hasSuffix("…"))
        XCTAssertFalse(hit.preview.contains("�"))
    }

    func testCancelledSearchThrowsAndChecksDuringWork() throws {
        try write("one", text: String(repeating: "needle ", count: 100))
        XCTAssertThrowsError(try ProjectTextSearch.search(root: root, paths: ["one"], query: "needle", isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        var checks = 0
        XCTAssertThrowsError(try ProjectTextSearch.search(root: root, paths: ["one"], query: "needle", isCancelled: {
            checks += 1
            return checks > 5
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThan(checks, 5)
    }

    func testEmptyQueryDoesNotReadFilesAndWhitespaceCanBeSearched() throws {
        try write("one", text: "a b  c")
        let empty = try ProjectTextSearch.search(root: root, paths: ["one"], query: "")
        XCTAssertEqual(empty.hits, [])
        XCTAssertEqual(empty.scannedFiles, 0)
        XCTAssertNil(empty.notice)
        XCTAssertEqual(try ProjectTextSearch.search(root: root, paths: ["one"], query: "  ").hits.count, 1)
    }

    private func limits(fileBytes: Int = 2 * 1_024 * 1_024, totalBytes: Int = 64 * 1_024 * 1_024,
                        files: Int = 5_000, hits: Int = 1_000, hitsPerFile: Int = 200) -> ProjectTextSearch.Limits {
        .init(maximumFileBytes: fileBytes, maximumTotalBytes: totalBytes, maximumFiles: files,
              maximumHits: hits, maximumHitsPerFile: hitsPerFile)
    }

    private func write(_ path: String, text: String) throws { try write(path, bytes: Data(text.utf8)) }

    private func write(_ path: String, bytes: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
}
