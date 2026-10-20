import XCTest
import AppKit
@testable import Folmi
import FolmiCore

@MainActor
final class FilePreviewTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func write(_ path: String, _ data: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testKindsByExtension() {
        for path in ["a.png", "b/c.JPG", "d.gif", "e.webp", "f.heic", "g.svg", "h.ico"] { XCTAssertEqual(FilePreviewKind(path: path), .image) }
        for path in ["报告.docx", "a.doc", "b.xlsx", "c.pptx", "d.pdf", "e.mp4", "f.mp3"] { XCTAssertEqual(FilePreviewKind(path: path), .document) }
        for path in ["a.swift", "README.md", "Dockerfile", "data.json"] { XCTAssertNil(FilePreviewKind(path: path)) }
        XCTAssertTrue(FilePreviewKind.hasSource("logo.svg"))
        XCTAssertFalse(FilePreviewKind.hasSource("logo.png"))
    }

    func testPicturesAndDocumentsOpenAsReadOnlyPreviewTabs() throws {
        try write("img/logo.png", png(width: 3, height: 2))
        try write("docs/方案.docx", Data([0x50, 0x4B, 0x03, 0x04, 0, 0]))
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "img/logo.png")
        try workspace.open(path: "docs/方案.docx")
        XCTAssertEqual(workspace.documents.map(\.preview), [.image, .document])
        XCTAssertEqual(workspace.selectedDocumentID, "docs/方案.docx")
        // Typing into a preview tab changes nothing and never makes it dirty.
        workspace.updateText(id: "img/logo.png", text: "x")
        XCTAssertFalse(workspace.hasUnsavedChanges)
        XCTAssertEqual(workspace.sessionState().map(\.path), ["img/logo.png", "docs/方案.docx"])
    }

    func testBinaryAndOversizedFilesFallBackToAPreviewInsteadOfAnError() throws {
        try write("bin/tool.o", Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0]))
        try write("big.log", Data(repeating: 0x61, count: 2 * 1_024 * 1_024 + 1))
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "bin/tool.o")
        try workspace.open(path: "big.log")
        // An unknown binary gets the info card; oversized text goes to Quick Look, which shows text.
        XCTAssertEqual(workspace.documents.map(\.preview), [.file, .document])
        XCTAssertEqual(workspace.notice, "文件超过 2 MiB，只能预览")
        XCTAssertNil(workspace.errorMessage)
    }

    func testPreviewOutsideTheProjectIsStillRefused() throws {
        let workspace = EditorWorkspace(root: root)
        XCTAssertThrowsError(try workspace.open(path: "../outside.png")) { XCTAssertEqual($0 as? FileEditorError, .unsafePath) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).png")
        try png(width: 1, height: 1).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"), withDestinationURL: outside)
        XCTAssertThrowsError(try workspace.open(path: "link.png")) { XCTAssertEqual($0 as? FileEditorError, .symbolicLink) }
        XCTAssertTrue(workspace.documents.isEmpty)
    }

    func testSVGPreviewCanSwitchToItsSource() throws {
        try write("icon.svg", Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>"#.utf8))
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "icon.svg")
        XCTAssertEqual(workspace.selectedDocument?.preview, .image)
        try workspace.open(path: "icon.svg", asText: true)
        XCTAssertEqual(workspace.documents.count, 1)
        XCTAssertNil(workspace.selectedDocument?.preview)
        XCTAssertTrue(workspace.selectedDocument?.text.hasPrefix("<svg") == true)
        XCTAssertEqual(SyntaxLanguage(path: "icon.svg"), .xml)
    }

    func testChangedPictureOnDiskRefreshesThePreview() throws {
        try write("shot.png", png(width: 2, height: 2))
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "shot.png")
        let before = try XCTUnwrap(workspace.selectedDocument?.fingerprint)
        XCTAssertTrue(workspace.reloadCleanDocuments().isEmpty)
        try write("shot.png", png(width: 40, height: 30))
        XCTAssertEqual(workspace.reloadCleanDocuments(), ["shot.png"])
        XCTAssertNotEqual(workspace.selectedDocument?.fingerprint, before)
        XCTAssertNotNil(workspace.externalChanges["shot.png"])
    }

    func testPixelSizeComesFromTheBitmapNotThePointSize() throws {
        let url = root.appendingPathComponent("retina.png")
        try png(width: 200, height: 100).write(to: url)
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        image.size = NSSize(width: 100, height: 50)
        XCTAssertEqual(ZoomableImageView.pixelSize(of: image), CGSize(width: 200, height: 100))
    }
}

@MainActor
final class ChangePreviewTests: XCTestCase {
    func testSameBytesReuseOneTemporaryFileWithTheRealName() throws {
        let a = try ChangePreviewFiles.write(Data([1, 2, 3]), name: "劳动合同 (1).docx")
        let b = try ChangePreviewFiles.write(Data([1, 2, 3]), name: "劳动合同 (1).docx")
        let c = try ChangePreviewFiles.write(Data([1, 2, 4]), name: "劳动合同 (1).docx")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.lastPathComponent, "劳动合同 (1).docx")
        XCTAssertEqual(try Data(contentsOf: c), Data([1, 2, 4]))
    }
}

@MainActor
final class ChangeCompareTests: XCTestCase {
    func testWordTextIsOneSentencePerLine() {
        XCTAssertEqual(WordText.sentences("第一条 期限。试用期三个月！\r\n\n  乙方同意？ok\u{2029}end"),
                       "第一条 期限。\n试用期三个月！\n乙方同意？\nok\nend\n")
        XCTAssertTrue(WordText.canRead("a.docx"))
        XCTAssertTrue(WordText.canRead("a.RTF"))
        XCTAssertFalse(WordText.canRead("a.pages"))
        XCTAssertFalse(WordText.canRead("a.pdf"))
    }

    func testWordTextReadsADocxAndTheDiffFindsTheChangedSentence() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("word-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func docx(_ text: String, _ name: String) throws -> URL {
            let data = try NSAttributedString(string: text).data(from: NSRange(location: 0, length: (text as NSString).length),
                                                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        let old = try docx("甲方：公司。试用期一个月。工资五千。", "old.docx")
        let new = try docx("甲方：公司。试用期三个月。工资五千。", "new.docx")
        let before = try XCTUnwrap(WordText.text(of: old, path: "合同.docx"))
        let after = try XCTUnwrap(WordText.text(of: new, path: "合同.docx"))
        XCTAssertEqual(before, "甲方：公司。\n试用期一个月。\n工资五千。\n")
        let initialize = Process()
        initialize.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initialize.arguments = ["init", "-q", "--template=", folder.path]
        try initialize.run(); initialize.waitUntilExit()
        let repo = GitRepository(url: folder)
        let diff = try await repo.contentDiff(path: "合同.docx.txt", before: Data(before.utf8), after: Data(after.utf8))
        let changed = diff.hunks.flatMap(\.lines).filter { $0.kind != .context }.map(\.text)
        XCTAssertEqual(changed, ["试用期一个月。", "试用期三个月。"])
    }

    func testFittingAndCompareBoxes() {
        let small = LoadedImage(image: NSImage(size: NSSize(width: 10, height: 10)), pixelSize: CGSize(width: 100, height: 50), isVector: false)
        let big = LoadedImage(image: NSImage(size: NSSize(width: 10, height: 10)), pixelSize: CGSize(width: 2000, height: 1000), isVector: false)
        let vector = LoadedImage(image: NSImage(size: NSSize(width: 10, height: 10)), pixelSize: CGSize(width: 100, height: 50), isVector: true)
        // Bitmaps never grow past their pixels; vectors and big pictures fit the space.
        XCTAssertEqual(FittedImage.fit(small, in: CGSize(width: 824, height: 424)), CGSize(width: 100, height: 50))
        XCTAssertEqual(FittedImage.fit(vector, in: CGSize(width: 824, height: 424)), CGSize(width: 800, height: 400))
        XCTAssertEqual(FittedImage.fit(big, in: CGSize(width: 1024, height: 1024)), CGSize(width: 1000, height: 500))
        XCTAssertEqual(ImageCompareView.box(small, big, in: CGSize(width: 1024, height: 1024)), CGSize(width: 1000, height: 500))
    }

    func testBigPicturesAreDecodedSmallButKeepTheirPixelSize() async throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3_000, pixelsHigh: 1_000, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try await XCTUnwrapAsync(await LoadedImage.load(url, maxPixels: 600))
        XCTAssertEqual(loaded.pixelSize, CGSize(width: 3_000, height: 1_000))
        XCTAssertFalse(loaded.isVector)
        let decoded = try XCTUnwrap(loaded.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 600)
        let svg = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString).svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"/>"#.utf8).write(to: svg)
        defer { try? FileManager.default.removeItem(at: svg) }
        let vector = try await XCTUnwrapAsync(await LoadedImage.load(svg))
        XCTAssertTrue(vector.isVector)
        XCTAssertEqual(vector.pixelSize, CGSize(width: 40, height: 20))
    }

    func testPreviewFolderBelongsToThisApp() {
        XCTAssertTrue(ChangePreviewFiles.folder.lastPathComponent.hasPrefix("folmi-change-previews-"))
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
