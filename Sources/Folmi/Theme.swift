import AppKit
import SwiftUI

// MARK: - Theme data

/// An sRGB color with alpha. Themes are plain data so a new one is only a list of values.
struct ThemeRGB: Hashable, Sendable, ExpressibleByIntegerLiteral {
    let hex: UInt32
    let alpha: CGFloat
    init(_ hex: UInt32, _ alpha: CGFloat = 1) { self.hex = hex; self.alpha = alpha }
    init(integerLiteral value: UInt32) { self.init(value) }

    private var red: CGFloat { CGFloat((hex >> 16) & 255) / 255 }
    private var green: CGFloat { CGFloat((hex >> 8) & 255) / 255 }
    private var blue: CGFloat { CGFloat(hex & 255) / 255 }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    func opacity(_ value: CGFloat) -> ThemeRGB { ThemeRGB(hex, alpha * value) }
    /// WCAG relative luminance, for picking dark or light text on a solid fill.
    var luminance: CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    func contrast(with other: ThemeRGB) -> CGFloat {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// A matte primary-button fill and the mineral colors used by its transient interaction particles.
struct ThemeMaterial: Sendable {
    let top: ThemeRGB
    let bottom: ThemeRGB
    let text: ThemeRGB
    let speckles: [ThemeRGB]
}

/// One light/dark variant of a theme, by meaning rather than by place.
struct ThemeColors: Sendable {
    /// Window floor, rail and status bar.
    var canvas: ThemeRGB
    /// Block (card) body.
    var card: ThemeRGB
    /// Block title strips and tab bars.
    var header: ThemeRGB
    var editorBackground: ThemeRGB
    var gutter: ThemeRGB
    var border: ThemeRGB
    var foreground: ThemeRGB
    var secondaryText: ThemeRGB
    var tertiaryText: ThemeRGB
    var hover: ThemeRGB
    /// Selected rows and tabs: a neutral fill, so the accent stays for primary actions.
    var selectedFill: ThemeRGB
    var accent: ThemeRGB
    /// Text and icons drawn on the accent.
    var onAccent: ThemeRGB
    var added: ThemeRGB
    var removed: ThemeRGB
    /// Modified files, warnings, conflicts.
    var modified: ThemeRGB
    var comment: ThemeRGB
    var keyword: ThemeRGB
    var string: ThemeRGB
    var number: ThemeRGB
    var type: ThemeRGB
    var variable: ThemeRGB
    var selection: ThemeRGB
    var link: ThemeRGB
    /// Primary buttons use this instead of a flat accent when set.
    var primaryMaterial: ThemeMaterial? = nil
    /// A soft light at the top of the window floor when glass is off.
    var backdropGlow: ThemeRGB? = nil
    /// The fill of a solid modified mark when `modified` itself must stay dark enough to read as text.
    var modifiedMark: ThemeRGB? = nil
    /// Colors along progress bars, left to right; nil uses the accent.
    var progress: [ThemeRGB]? = nil
    /// The solid offset shadow under cards and keys when it should differ from the edge (dark 像素: a light edge on a
    /// black shadow, so the step still reads on a dark floor).
    var shadow: ThemeRGB? = nil

    var hardShadow: ThemeRGB { shadow ?? border }

    subscript(token: ThemeToken) -> ThemeRGB {
        switch token {
        case .canvas: return canvas
        case .card: return card
        case .header: return header
        case .border: return border
        case .foreground: return foreground
        case .secondaryText: return secondaryText
        case .tertiaryText: return tertiaryText
        case .hover: return hover
        case .selectedFill: return selectedFill
        case .accent: return accent
        case .onAccent: return onAccent
        case .added: return added
        case .removed: return removed
        case .modified: return modified
        case .link: return link
        }
    }

    /// The fill of a solid status mark (M / A / D, status-bar squares) in this token's color.
    func markFill(_ token: ThemeToken) -> ThemeRGB { token == .modified ? modifiedMark ?? modified : self[token] }
}

/// Theme colors that chrome views pick by name.
enum ThemeToken: Sendable {
    case canvas, card, header, border, foreground, secondaryText, tertiaryText, hover, selectedFill
    case accent, onAccent, added, removed, modified, link
}

enum ThemeCorner: Sendable { case row, control, card }

/// Shape, edge and type of a theme, separate from its colors.
struct ThemeStyle: Sendable {
    enum Shadow: Sendable {
        /// No shadow; cards sit on the floor by their edge alone (锌莓).
        case none
        /// A light blur under cards.
        case soft
        /// A wide, warm-tinted blur (琥珀).
        case warm
        /// A solid offset copy of the border color (pixel).
        case hard(CGFloat)
        /// A deeper, lifted blur with a lit top edge.
        case lifted
    }
    enum Typeface: Sendable { case standard, rounded, monospaced }
    /// Card header tabs (改动 / 文件, 差异 / 编辑, editor and terminal tabs).
    enum Tabs: Sendable {
        /// A rounded fill behind the chosen tab.
        case fill
        /// A capsule fill (琥珀).
        case capsule
        /// A 2 pt accent line under the chosen tab, no fill (锌莓).
        case underline
        /// A lifted card-colored thumb on a neutral track, like a native segmented control (石墨).
        case segmented
    }
    /// How a selected row in a list reads.
    enum Selection: Sendable {
        /// A neutral (or the palette's) fill.
        case tint
        /// A neutral fill with a 2 pt accent bar on the leading edge (锌莓).
        case bar
        /// The accent itself with the on-accent text while the list's card has focus, neutral when it does not, like
        /// Finder (石墨).
        case solid
    }
    /// Status letters (M / A / D / U) when the theme does not use solid marks.
    enum Marks: Sendable {
        /// The letter on a soft fill of its color.
        case tint
        /// The colored letter alone, monospaced (锌莓).
        case text
        /// A small dot in the color, then the letter in a quiet tone (石墨).
        case dot
    }
    /// The primary button.
    enum Prominent: Sendable {
        /// The accent in the control corner.
        case flat
        /// A capsule with a darker bottom edge that it sinks into when pressed (琥珀).
        case clay
        /// A square-cornered accent button (锌莓).
        case sharp
    }

    var rowRadius: CGFloat
    var controlRadius: CGFloat
    var cardRadius: CGFloat
    var borderWidth: CGFloat
    var shadow: Shadow
    var typeface: Typeface
    /// A faint checker over the window floor.
    var dither = false
    /// Progress bars as hard color steps instead of a gradient.
    var steppedProgress = false
    /// Interface text in the bundled pixel font (Fusion Pixel, CJK included) instead of the system font.
    var pixelFont = false
    /// Status letters as solid color blocks, and colored squares in the status bar, instead of soft tints.
    var solidMarks = false
    /// The focused card's top line: a 2 pt soft accent, or a heavier solid one.
    var focusLineWidth: CGFloat = 2
    var focusLineOpacity: Double = 0.75
    var tabs: Tabs = .fill
    var selection: Selection = .tint
    var marks: Marks = .tint
    var prominent: Prominent = .flat
    /// Cards draw no edge; depth comes from the surfaces' own tones (石墨).
    var borderless = false
    /// Extra vertical room in change-list rows: negative for a dense list, positive for a roomy one.
    var rowPadding: CGFloat = 3
    /// Counts, branches and the status bar in a monospaced face, and each changed file's +N −N (锌莓).
    var instrument = false
    /// The focus line draws in from the leading edge when a card takes focus (锌莓).
    var focusSweep = false
    /// The Folmi mascot keeps the user company in the status bar, the AI tab and the done page (琥珀).
    var companion = false
    /// The floor showing between cards.
    var paneGap: CGFloat = 10

    func radius(_ corner: ThemeCorner) -> CGFloat {
        switch corner { case .row: return rowRadius; case .control: return controlRadius; case .card: return cardRadius }
    }
    var fontDesign: Font.Design {
        switch typeface { case .standard: return .default; case .rounded: return .rounded; case .monospaced: return .monospaced }
    }
    var isSquare: Bool { cardRadius == 0 }

    static let flat = ThemeStyle(rowRadius: 7, controlRadius: 8, cardRadius: 12, borderWidth: 1, shadow: .soft, typeface: .standard)
    /// 暖陶: big soft corners, the rounded face, capsule controls and a clay primary button, roomy rows, Folmi nearby.
    static let amber = ThemeStyle(rowRadius: 10, controlRadius: 10, cardRadius: 18, borderWidth: 1, shadow: .warm, typeface: .rounded,
                                  tabs: .capsule, prominent: .clay, rowPadding: 5, companion: true)
    /// 精密: tight corners, edges instead of shadows, dense rows, monospaced figures and an accent line for focus.
    static let zinc = ThemeStyle(rowRadius: 0, controlRadius: 4, cardRadius: 6, borderWidth: 1, shadow: .none, typeface: .standard,
                                 focusLineWidth: 1, focusLineOpacity: 1, tabs: .underline, selection: .bar, marks: .text,
                                 prominent: .sharp, rowPadding: 1, instrument: true, focusSweep: true, paneGap: 6)
    static let pixel = ThemeStyle(rowRadius: 0, controlRadius: 0, cardRadius: 0, borderWidth: 2, shadow: .hard(3), typeface: .monospaced,
                                  steppedProgress: true, pixelFont: true, solidMarks: true,
                                  focusLineWidth: 2, focusLineOpacity: 1)
    /// Apple: concentric corners (card 16 = row 10 + 6 inset), no edges, the system face, a native segmented switch,
    /// Finder-style selection.
    static let terrazzo = ThemeStyle(rowRadius: 10, controlRadius: 8, cardRadius: 16, borderWidth: 1, shadow: .soft, typeface: .standard,
                                     tabs: .segmented, selection: .solid, marks: .dot, borderless: true)
}

struct ThemeDefinition: Sendable {
    let id: String
    let title: String
    let detail: String
    let style: ThemeStyle
    let light: ThemeColors
    let dark: ThemeColors
    func colors(dark isDark: Bool) -> ThemeColors { isDark ? dark : light }
    /// Text on a solid mark: the light theme's ink or the dark theme's paper, whichever reads better on `fill`.
    func markText(on fill: ThemeRGB) -> ThemeRGB {
        fill.contrast(with: light.foreground) >= fill.contrast(with: dark.foreground) ? light.foreground : dark.foreground
    }
}

/// The chosen theme, saved by id. Light/dark is chosen separately (跟随系统 / 浅色 / 深色); every theme has both.
struct FolmiTheme: RawRepresentable, Hashable, Codable, Sendable, CaseIterable {
    let rawValue: String
    /// Ids of removed themes map to the fallback; ids never seen return nil, so decoding falls back too.
    init?(rawValue: String) {
        if ThemeCatalog.definition(rawValue) != nil { self.rawValue = rawValue }
        else if ThemeCatalog.retiredIDs.contains(rawValue) { self.rawValue = ThemeCatalog.fallback.id }
        else { return nil }
    }
    private init(id: String) { rawValue = id }

    static let indigo = FolmiTheme(id: ThemeCatalog.indigo.id)
    static let zinc = FolmiTheme(id: ThemeCatalog.zinc.id)
    static let pixel = FolmiTheme(id: ThemeCatalog.pixel.id)
    static let terrazzo = FolmiTheme(id: ThemeCatalog.terrazzo.id)
    static var standard: FolmiTheme { FolmiTheme(id: ThemeCatalog.fallback.id) }
    static var allCases: [FolmiTheme] { ThemeCatalog.all.map { FolmiTheme(id: $0.id) } }

    var definition: ThemeDefinition { ThemeCatalog.definition(rawValue) ?? ThemeCatalog.fallback }
    var title: String { definition.title }
    var detail: String { definition.detail }
    var style: ThemeStyle { definition.style }
    var palette: ThemePalette { ThemePalette.of(self) }

    /// Stone stays opaque even when the shared glass preference is enabled. Other themes retain that preference.
    func usesGlass(requested: Bool, reduceTransparency: Bool = false, increaseContrast: Bool = false) -> Bool {
        self != .terrazzo && requested && !reduceTransparency && !increaseContrast
    }
}

// MARK: - AppKit palette

/// Appearance-adaptive colors. Each is a dynamic NSColor, so AppKit drawing and SwiftUI both pick the right variant
/// for the view's own appearance; `resolved(dark:)` fixes one variant for text attributes.
struct ThemePalette {
    let canvas: NSColor
    let card: NSColor
    let header: NSColor
    let border: NSColor
    let accent: NSColor
    let onAccent: NSColor
    let foreground: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let hover: NSColor
    let selectedFill: NSColor
    let added: NSColor
    let removed: NSColor
    let modified: NSColor
    let editorBackground: NSColor
    let gutter: NSColor
    let comment: NSColor
    let keyword: NSColor
    let string: NSColor
    let number: NSColor
    let type: NSColor
    let variable: NSColor
    let selection: NSColor
    let link: NSColor

    init(_ theme: ThemeDefinition) {
        let d = theme.dark, l = theme.light
        func pick(_ key: KeyPath<ThemeColors, ThemeRGB>) -> NSColor { Self.pair(d[keyPath: key], l[keyPath: key]) }
        canvas = pick(\.canvas); card = pick(\.card); header = pick(\.header); border = pick(\.border)
        accent = pick(\.accent); onAccent = pick(\.onAccent); foreground = pick(\.foreground)
        secondaryText = pick(\.secondaryText); tertiaryText = pick(\.tertiaryText); hover = pick(\.hover); selectedFill = pick(\.selectedFill)
        added = pick(\.added); removed = pick(\.removed); modified = pick(\.modified)
        editorBackground = pick(\.editorBackground); gutter = pick(\.gutter); comment = pick(\.comment); keyword = pick(\.keyword)
        string = pick(\.string); number = pick(\.number); type = pick(\.type); variable = pick(\.variable)
        selection = pick(\.selection); link = pick(\.link)
    }

    private static let cache: [String: ThemePalette] = Dictionary(uniqueKeysWithValues: ThemeCatalog.all.map { ($0.id, ThemePalette($0)) })

    static func of(_ theme: FolmiTheme) -> ThemePalette { cache[theme.rawValue] ?? ThemePalette(theme.definition) }

    /// The palette of the window's current theme, for AppKit views drawn outside SwiftUI's environment.
    @MainActor static var current = ThemePalette.of(.standard)

    /// A color that follows the appearance it is drawn in.
    static func pair(_ dark: ThemeRGB, _ light: ThemeRGB) -> NSColor {
        let darkColor = dark.nsColor, lightColor = light.nsColor
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
    }
    static func hex(_ value: UInt32) -> NSColor { ThemeRGB(value).nsColor }

    /// One fixed variant, for attributed text that should not change with an inherited appearance.
    static func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        var result = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }
}

private struct FolmiThemeKey: EnvironmentKey {
    static let defaultValue = FolmiTheme.standard
}

extension EnvironmentValues {
    var folmiTheme: FolmiTheme {
        get { self[FolmiThemeKey.self] }
        set { self[FolmiThemeKey.self] = newValue }
    }
}

extension Color {
    /// Theme color for SwiftUI chrome.
    @MainActor static func theme(_ theme: FolmiTheme, _ pick: (ThemePalette) -> NSColor) -> Color {
        Color(nsColor: pick(theme.palette))
    }
}

/// 外观 and 主题 choices, shared by the rail button, the toolbar menu and the app menu.
struct ThemeMenuItems: View {
    @Bindable var model: FolmiModel
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let _ = PerfLog.body("ThemeMenuItems")
        Section("明暗") {
            ForEach(FolmiAppearance.allCases, id: \.self) { appearance in
                Toggle(appearance.title, isOn: Binding(get: { model.appearance == appearance }, set: { if $0 { model.appearance = appearance } }))
            }
        }
        Section("主题") {
            ForEach(FolmiTheme.allCases, id: \.self) { theme in
                Toggle(theme.title, isOn: Binding(get: { model.theme == theme }, set: { if $0 { model.theme = theme } }))
                    .help(theme.detail)
            }
        }
        if model.theme.style.companion {
            Section("陪伴") {
                Toggle("陪伴动画", isOn: $model.companionMotion)
                    .help("Folmi 在 AI 标签页和收工页会动；关掉后只换表情。状态栏里的 Folmi 始终不动，文字总会说明发生了什么。")
            }
        }
        Section("材质") {
            if model.theme == .terrazzo {
                Label(colorScheme == .dark ? "哑光石墨" : "柔光石墨", systemImage: "checkmark")
            } else {
                Toggle("玻璃材质", isOn: $model.glassSurfaces)
                    .help("整个窗口透出模糊的桌面，各个块浮在上面，浮层带玻璃边缘。关掉后用主题实色；系统「降低透明度」或「增强对比度」打开时总是实色。")
            }
        }
    }
}

/// Markdown live-preview reading settings; the code font and size above stay for source and code.
struct MarkdownReadingMenu: View {
    @Bindable var model: FolmiModel
    var body: some View {
        let _ = PerfLog.body("MarkdownReadingMenu")
        Menu("Markdown 正文") {
            Section("字体") {
                ForEach(EditorPresentation.proseFamilies, id: \.id) { family in
                    Toggle(family.title, isOn: Binding(get: { model.markdownFontFamily == family.id },
                                                       set: { if $0 { model.markdownFontFamily = family.id } }))
                }
            }
            Section("字号") {
                ForEach(EditorPresentation.proseSizes, id: \.self) { size in
                    Toggle("\(Int(size)) pt", isOn: Binding(get: { model.markdownFontSize == size },
                                                           set: { if $0 { model.markdownFontSize = size } }))
                }
            }
            Section("阅读宽度") {
                ForEach(EditorPresentation.readingWidths, id: \.width) { option in
                    Toggle(option.title, isOn: Binding(get: { model.markdownReadingWidth == option.width },
                                                       set: { if $0 { model.markdownReadingWidth = option.width } }))
                }
            }
        }
        .help("只影响 Markdown 阅读视图；编辑（源码）和代码块仍用编辑器的代码字体。")
    }
}

extension FolmiAppearance {
    var symbol: String { switch self { case .system: return "circle.lefthalf.filled"; case .light: return "sun.max"; case .dark: return "moon" } }
}

/// Paints the title bar and toolbar with the theme canvas. SwiftUI's toolbarBackground does not reach the unified
/// macOS toolbar, so the window's titlebar goes transparent and shows the window background instead.
struct WindowChrome: NSViewRepresentable {
    @Environment(\.folmiTheme) private var theme
    let color: NSColor
    /// With glass the window goes clear so `WindowBackdrop` can show the blurred desktop, title bar included.
    var glass = false

    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) {
        PerfLog.body("WindowChrome.update")
        view.color = color
        view.glass = theme.usesGlass(requested: glass)
        view.apply()
    }

    final class ChromeView: NSView {
        var color: NSColor = .windowBackgroundColor
        var glass = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            let clear = glass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            window.isOpaque = !clear
            window.backgroundColor = clear ? .clear : color
        }
    }
}
