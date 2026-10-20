import AppKit
import SwiftUI
import XCTest
@testable import Folmi

final class ThemeTests: XCTestCase {
    private func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB)!
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }
    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @MainActor
    func testEveryThemeIsReadableInLightAndDark() {
        for theme in FolmiTheme.allCases {
            for dark in [false, true] {
                let palette = EditorPalette(presentation: EditorPresentation(appearance: dark ? .dark : .light, theme: theme), effectiveDark: dark)
                let label = "\(theme.title) \(dark ? "深色" : "浅色")"
                XCTAssertGreaterThanOrEqual(contrast(palette.foreground, palette.background), 4.5, label)
                for (name, color) in [("comment", palette.comment), ("keyword", palette.keyword), ("string", palette.string),
                                      ("number", palette.number), ("type", palette.type), ("variable", palette.variable), ("link", palette.link)] {
                    XCTAssertGreaterThanOrEqual(contrast(color, palette.background), 2.6, "\(label) \(name)")
                }
                XCTAssertEqual(luminance(palette.background) < 0.2, dark, "\(label) background follows light/dark")
                let card = ThemePalette.resolved(theme.palette.card, dark: dark), canvas = ThemePalette.resolved(theme.palette.canvas, dark: dark)
                XCTAssertNotEqual(card, canvas, "\(label) cards stand out from the window")
            }
        }
    }

    func testCatalogIsTheOnlyListOfThemes() {
        XCTAssertEqual(FolmiTheme.allCases.map(\.rawValue), ["indigo", "zinc", "pixel", "terrazzo"])
        XCTAssertEqual(Set(ThemeCatalog.all.map(\.id)).count, ThemeCatalog.all.count, "ids are unique")
        for theme in FolmiTheme.allCases {
            XCTAssertEqual(FolmiTheme(rawValue: theme.rawValue), theme)
            XCTAssertFalse(theme.title.isEmpty)
            XCTAssertLessThan(luminance(theme.definition.dark.canvas.nsColor), luminance(theme.definition.light.canvas.nsColor), theme.title)
        }
        XCTAssertEqual(FolmiTheme.pixel.style.cardRadius, 0)
        // Each theme has its own shape, not only its own colors.
        XCTAssertGreaterThan(FolmiTheme.indigo.style.cardRadius, FolmiTheme.terrazzo.style.cardRadius, "琥珀 is the softest")
        XCTAssertGreaterThan(FolmiTheme.terrazzo.style.cardRadius, FolmiTheme.zinc.style.cardRadius, "锌莓 is the tightest above pixel")
        XCTAssertEqual(FolmiTheme.terrazzo.style.cardRadius, FolmiTheme.terrazzo.style.rowRadius + 6, "石墨's corners are concentric")
        XCTAssertTrue(FolmiTheme.indigo.style.companion)
        XCTAssertTrue(FolmiTheme.zinc.style.instrument)
        XCTAssertEqual(FolmiTheme.terrazzo.style.selection, .solid)
        XCTAssertNotNil(FolmiTheme.terrazzo.definition.dark.primaryMaterial)
    }

    @MainActor
    func testEditorColorsComeFromTheDefinition() {
        let dark = EditorPalette(presentation: EditorPresentation(appearance: .dark, theme: .indigo), effectiveDark: true)
        XCTAssertEqual(dark.background, ThemePalette.hex(0x222429))
        XCTAssertEqual(dark.keyword, ThemePalette.hex(0xF2C676))
        let light = EditorPalette(presentation: EditorPresentation(appearance: .light, theme: .indigo), effectiveDark: true)
        XCTAssertEqual(light.foreground, ThemePalette.hex(0x222429), "an explicit light appearance wins over a dark system")
        XCTAssertNotEqual(EditorPalette(presentation: EditorPresentation(appearance: .dark, theme: .pixel), effectiveDark: true).background, dark.background)
    }

    func testFolmiAmberActionsAndLinksStayReadable() throws {
        let saved = try JSONDecoder().decode(WorkspacePreferences.self, from: Data(#"{"version":1,"theme":"indigo"}"#.utf8))
        XCTAssertEqual(saved.theme.title, "琥珀", "existing 靛石 preferences keep their selection")
        for colors in [saved.theme.definition.light, saved.theme.definition.dark] {
            XCTAssertEqual(colors.accent.hex, 0xE9AA47, "primary actions match the approved Folmi icon")
            XCTAssertGreaterThanOrEqual(contrast(colors.accent.nsColor, colors.onAccent.nsColor), 4.5,
                                        "amber buttons use readable charcoal labels")
            XCTAssertGreaterThanOrEqual(contrast(colors.link.nsColor, colors.editorBackground.nsColor), 4.5,
                                        "links remain readable on both backgrounds")
        }
    }

    func testThemeColorFollowsThemeAndScheme() {
        func rgb(_ color: NSColor?) -> [Int] {
            guard let c = color?.usingColorSpace(.sRGB) else { return [] }
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        var environment = EnvironmentValues()
        environment.folmiTheme = .pixel
        environment.colorScheme = .dark
        XCTAssertEqual(rgb(NSColor(ThemeColor(token: .accent).resolve(in: environment))), rgb(ThemePalette.hex(0x4C9BFF)))
        environment.colorScheme = .light
        XCTAssertEqual(rgb(NSColor(ThemeColor(token: .accent).resolve(in: environment))), rgb(ThemePalette.hex(0x1F6FEB)))
        environment.folmiTheme = .zinc
        XCTAssertEqual(rgb(NSColor(ThemeColor(token: .accent).resolve(in: environment))), rgb(ThemePalette.hex(0xB8326A)))
    }

    /// Themed fields, pills and default buttons render under every theme (a helper that calls itself would recurse).
    @MainActor
    func testThemedControlsRenderInEveryTheme() throws {
        for theme in FolmiTheme.allCases {
            let view = VStack {
                TextField("搜索改动…", text: .constant("")).themedTextField()
                Text("演示").themedCapsule(ThemeColor(token: .accent, opacity: 0.12))
                Button("暂存文件") {}
                Form { FormTextField(title: "模型", text: .constant(""), prompt: "deepseek-chat") }
                TextEditor(text: .constant("")).frame(height: 40).themedEditorFrame()
            }
            .buttonStyle(ThemedDefaultButtonStyle())
            .padding().frame(width: 240).environment(\.folmiTheme, theme)
            XCTAssertNotNil(ImageRenderer(content: view).nsImage, theme.title)
        }
    }

    func testPixelSolidMarksStayReadable() {
        let definition = FolmiTheme.pixel.definition
        XCTAssertTrue(definition.style.solidMarks)
        for dark in [false, true] {
            let colors = definition.colors(dark: dark)
            for token in [ThemeToken.added, .removed, .modified] {
                let fill = colors.markFill(token)
                XCTAssertGreaterThanOrEqual(fill.contrast(with: definition.markText(on: fill)), 4.5,
                                            "\(token) mark letter is readable (dark: \(dark))")
            }
        }
        // The bright coin-yellow fill is for marks only; modified text stays dark enough to read on cards.
        XCTAssertGreaterThanOrEqual(definition.light.modified.contrast(with: definition.light.card), 4.5)
    }

    func testThemePersistsAndOldOrUnknownValuesFallBack() throws {
        var preferences = WorkspacePreferences()
        XCTAssertEqual(preferences.theme, .indigo)
        preferences.theme = .terrazzo
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePreferences.self, from: data).theme, .terrazzo)
        for old in ["one", "paper", "native"] {
            let saved = try JSONDecoder().decode(WorkspacePreferences.self, from: Data(#"{"version":1,"theme":"\#(old)"}"#.utf8))
            XCTAssertEqual(saved.theme, .indigo, old)
        }
        let future = try JSONDecoder().decode(WorkspacePreferences.self, from: Data(#"{"version":1,"theme":"neon","showTerminal":true}"#.utf8))
        XCTAssertEqual(future.theme, .indigo)
        XCTAssertTrue(future.showTerminal, "an unknown theme does not discard the rest of the file")
    }

    @MainActor
    func testModelAndTerminalFollowTheTheme() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.theme = .terrazzo
        XCTAssertEqual(model.editorPresentation.theme, .terrazzo)
        XCTAssertEqual(ThemePalette.current.accent, FolmiTheme.terrazzo.palette.accent, "AppKit drawing follows the theme")
        model.appearance = .dark
        XCTAssertEqual(model.theme, .terrazzo, "light/dark is chosen apart from the theme")

        let root = directory.appendingPathComponent("term", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = TerminalSession(root: root, environment: [:], isDemo: true)
        defer { session.stop() }
        let view = session.terminalView
        view.appearance = NSAppearance(named: .aqua)
        view.theme = .terrazzo
        XCTAssertEqual(view.nativeBackgroundColor.usingColorSpace(.sRGB), ThemePalette.hex(0xFFFFFF).usingColorSpace(.sRGB))
        view.appearance = NSAppearance(named: .darkAqua)
        view.applyAppearanceColors()
        XCTAssertEqual(view.nativeBackgroundColor.usingColorSpace(.sRGB), ThemePalette.hex(0x212325).usingColorSpace(.sRGB))
    }

    /// A click effect must never exist at rest or cover the button label, at any sampled frame.
    func testTerrazzoClickParticlesAreTransientAndOutsideTheLabel() {
        for kind in [TerrazzoParticleKind.activation, .completion] {
            let size = CGSize(width: 140, height: 28)
            XCTAssertTrue(TerrazzoParticleGeometry.grains(size: size, progress: 0, kind: kind).isEmpty)
            XCTAssertTrue(TerrazzoParticleGeometry.grains(size: size, progress: 1, kind: kind).isEmpty)
            for progress in stride(from: 0.05, to: 1, by: 0.05) {
                let grains = TerrazzoParticleGeometry.grains(size: size, progress: progress, kind: kind)
                XCTAssertFalse(grains.isEmpty)
                for grain in grains {
                    XCTAssertTrue(grain.center.y + grain.radius < 0 || grain.center.y - grain.radius > size.height)
                    XCTAssertTrue((0...1).contains(grain.opacity))
                }
            }
        }
    }

    @MainActor
    func testTerrazzoWelcomeUsesTheBundledMascot() {
        let dots = TerrazzoMarkGeometry.dots
        XCTAssertGreaterThan(dots.count, 100)
        XCTAssertLessThan(dots.count, 1000, "the mark stays inexpensive to animate")
        XCTAssertTrue(dots.allSatisfy { (0...1).contains($0.point.x) && (0...1).contains($0.point.y) })
        XCTAssertTrue(dots.contains(where: \.ink), "the mascot's facial detail is preserved")
    }
}
