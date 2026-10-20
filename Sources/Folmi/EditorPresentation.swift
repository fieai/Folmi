import Foundation
import AppKit

enum FolmiAppearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
}

struct EditorPresentation: Equatable, Sendable {
    var fontFamily: String
    var fontSize: Double
    var lineHeight: Double
    var tabSize: Int
    var wrapLines: Bool
    var appearance: FolmiAppearance
    var theme: FolmiTheme
    /// Markdown live-preview body text, set apart from the code font: "" is the system font, "serif" the system serif.
    var proseFontFamily: String
    var proseFontSize: Double
    /// Longest wrapped line in live preview, in points; 0 means as wide as the editor.
    var readingWidth: Double

    init(fontFamily: String = "JetBrains Mono", fontSize: Double = 18, lineHeight: Double = 22,
         tabSize: Int = 2, wrapLines: Bool = true, appearance: FolmiAppearance = .system, theme: FolmiTheme = .standard,
         proseFontFamily: String = "", proseFontSize: Double = 16, readingWidth: Double = 720) {
        self.fontFamily = fontFamily; self.fontSize = fontSize; self.lineHeight = lineHeight
        self.tabSize = tabSize; self.wrapLines = wrapLines; self.appearance = appearance; self.theme = theme
        self.proseFontFamily = proseFontFamily; self.proseFontSize = proseFontSize; self.readingWidth = readingWidth
    }

    static let proseFamilies: [(id: String, title: String)] = [("", "系统字体"), ("serif", "系统衬线"), ("PingFang SC", "苹方")]
    static let proseSizes: [Double] = [15, 16, 17, 18, 20]
    static let readingWidths: [(width: Double, title: String)] = [(640, "窄（640）"), (720, "标准（720）"), (860, "宽（860）"), (0, "不限")]

    @MainActor func font(weight: NSFont.Weight = .regular) -> NSFont {
        let size = CGFloat(fontSize.isFinite ? min(40, max(8, fontSize)) : 18)
        let base = NSFont(name: fontFamily, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        return weight == .regular ? base : NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }

    @MainActor func paragraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let height = CGFloat(lineHeight.isFinite ? min(80, max(fontSize, lineHeight)) : max(fontSize, 22))
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        let advance = (" " as NSString).size(withAttributes: [.font: font()]).width
        paragraph.defaultTabInterval = max(1, advance * CGFloat(min(8, max(1, tabSize))))
        paragraph.tabStops = []
        return paragraph
    }
}

/// Fixed source-editing and Markdown colors for the chosen theme and light/dark variant.
/// The selected appearance belongs only to this app.
@MainActor
struct EditorPalette {
    let isDark: Bool
    let theme: FolmiTheme
    init(presentation: EditorPresentation, effectiveDark: Bool) {
        isDark = presentation.appearance == .dark || (presentation.appearance == .system && effectiveDark)
        theme = presentation.theme
    }
    var foreground: NSColor { color(\.foreground) }
    var background: NSColor { color(\.editorBackground) }
    var gutter: NSColor { color(\.gutter) }
    var comment: NSColor { color(\.comment) }
    var keyword: NSColor { color(\.keyword) }
    var string: NSColor { color(\.string) }
    var number: NSColor { color(\.number) }
    var type: NSColor { color(\.type) }
    var variable: NSColor { color(\.variable) }
    var selection: NSColor { color(\.selection) }
    var link: NSColor { color(\.link) }
    private func color(_ pick: KeyPath<ThemePalette, NSColor>) -> NSColor {
        ThemePalette.resolved(theme.palette[keyPath: pick], dark: isDark)
    }
}

struct EditorTabState: Codable, Equatable, Sendable {
    var path: String
    var selectionLocation: Int
    var selectionLength: Int
    var scrollOffset: Double
    init(path: String, selectionLocation: Int = 0, selectionLength: Int = 0, scrollOffset: Double = 0) {
        self.path = path; self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength; self.scrollOffset = scrollOffset
    }
    // Saved tabs from before may still carry "folded" (heading folds of the old live Markdown mode); it is ignored.
    private enum CodingKeys: String, CodingKey { case path, selectionLocation, selectionLength, scrollOffset }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        selectionLocation = (try? values.decode(Int.self, forKey: .selectionLocation)) ?? 0
        selectionLength = (try? values.decode(Int.self, forKey: .selectionLength)) ?? 0
        scrollOffset = (try? values.decode(Double.self, forKey: .scrollOffset)) ?? 0
    }
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git"
        }
    }
}

enum EditorTextPosition {
    /// Sessions and search use UTF-16, then round to complete composed characters for AppKit selections.
    static func clamp(_ range: NSRange, in text: String) -> NSRange {
        let source = text as NSString
        let start = min(source.length, max(0, range.location))
        let length = min(max(0, range.length), source.length - start)
        guard length > 0 else {
            if start < source.length { return NSRange(location: source.rangeOfComposedCharacterSequence(at: start).location, length: 0) }
            return NSRange(location: start, length: 0)
        }
        return source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: length))
    }
    static func range(line: Int, column: Int, in text: String) -> NSRange {
        let source = text as NSString
        var offset = 0
        var currentLine = 1
        while currentLine < max(1, line), offset < source.length {
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            currentLine += 1
        }
        guard offset < source.length else { return NSRange(location: source.length, length: 0) }
        let lineRange = source.lineRange(for: NSRange(location: offset, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > offset, [10, 13, 0x2028, 0x2029].contains(source.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let requested = min(max(1, column) - 1, contentEnd - offset)
        return clamp(NSRange(location: offset + requested, length: 0), in: text)
    }
}
