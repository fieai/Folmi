import XCTest
import SwiftUI
@testable import Folmi

final class PixelFontTests: XCTestCase {
    @MainActor
    func testPixelFontIsBundledAndRegisters() throws {
        XCTAssertNotNil(PixelFont.fileURL)
        XCTAssertTrue(PixelFont.isAvailable)
        let font = try XCTUnwrap(NSFont(name: PixelFont.postScriptName, size: 12))
        // The Simplified Chinese build covers everyday CJK and the interface's own words.
        let text = "暂存区工作区收起的改动拉取" as NSString
        var glyphs = [CGGlyph](repeating: 0, count: text.length)
        var units = [UniChar](repeating: 0, count: text.length)
        text.getCharacters(&units)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font as CTFont, &units, &glyphs, units.count))
        XCTAssertEqual(PixelFont.size(for: 10), 12); XCTAssertEqual(PixelFont.size(for: 17), 12); XCTAssertEqual(PixelFont.size(for: 26), 24)
        XCTAssertTrue(FolmiTheme.allCases.contains { $0.style.pixelFont }, "the 像素 theme asks for it")
        XCTAssertEqual(FolmiTheme.allCases.filter { $0.style.pixelFont }.count, 1, "and only that theme")
    }

    @MainActor
    func testRenderSample() throws {
        let theme = FolmiTheme.allCases.first { $0.style.pixelFont }!
        let view = VStack(alignment: .leading) {
            Text("暂存区 1 将会提交 README.md").themedFont(.caption, points: 10)
            Text("暂存区 1 将会提交 README.md").font(.caption)
        }.padding().background(Color.white).environment(\.folmiTheme, theme)
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "pixel-sample.png"))
    }
    /// The bundled font is cut down (scripts/subset-pixel-font.py). Every non-ASCII character in the app's own source
    /// must still be in it; when this fails, a new interface word needs the script run again.
    @MainActor
    func testSubsetCoversEveryCharacterInSources() throws {
        let font = try XCTUnwrap(NSFont(name: PixelFont.postScriptName, size: 12))
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var characters = Set<UInt16>()
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            for unit in try String(contentsOf: url, encoding: .utf8).utf16 where unit >= 0x3000 && unit < 0xD800 { characters.insert(unit) }
        }
        var missing: [String] = []
        for unit in characters.sorted() {
            var character = unit, glyph: CGGlyph = 0
            if !CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1) { missing.append(String(utf16CodeUnits: [unit], count: 1)) }
        }
        XCTAssertTrue(missing.isEmpty, "像素字体缺字，运行 scripts/subset-pixel-font.py：\(missing.prefix(20).joined())")
        XCTAssertGreaterThan(characters.count, 500)
    }
}
