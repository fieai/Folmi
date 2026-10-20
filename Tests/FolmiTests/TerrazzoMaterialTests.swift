import XCTest
@testable import Folmi

final class TerrazzoMaterialTests: XCTestCase {
    func testStoneChromeStaysOpaqueWithoutChangingTheSharedGlassPreference() {
        for requested in [false, true] {
            for reduceTransparency in [false, true] {
                for increaseContrast in [false, true] {
                    XCTAssertFalse(FolmiTheme.terrazzo.usesGlass(requested: requested,
                        reduceTransparency: reduceTransparency, increaseContrast: increaseContrast))
                    for theme in FolmiTheme.allCases where theme != .terrazzo {
                        XCTAssertEqual(theme.usesGlass(requested: requested,
                            reduceTransparency: reduceTransparency, increaseContrast: increaseContrast),
                            requested && !reduceTransparency && !increaseContrast,
                            "\(theme.title) keeps its existing glass and accessibility behavior")
                    }
                }
            }
        }
    }

    func testStoneInterfaceTextIsReadableOnEverySolidSurface() {
        for dark in [false, true] {
            let colors = ThemeCatalog.terrazzo.colors(dark: dark)
            for surface in [colors.canvas, colors.card, colors.header, colors.editorBackground, colors.gutter] {
                XCTAssertEqual(surface.alpha, 1, "stone surfaces are opaque")
                for text in [colors.foreground, colors.secondaryText, colors.tertiaryText] {
                    XCTAssertGreaterThanOrEqual(text.contrast(with: surface), 4.5,
                        "Interface text must be readable across all stone surfaces (dark: \(dark))")
                }
            }
            XCTAssertGreaterThanOrEqual(colors.foreground.contrast(with: colors.selection), 4.5)
            if dark {
                XCTAssertNil(colors.backdropGlow, "dark matte stone keeps its existing floor")
            } else {
                XCTAssertEqual(colors.backdropGlow?.hex, 0xFFFFFF, "light stone restores its original soft top light")
            }
        }
    }

    func testStoneSyntaxAndActionLabelsMeetNormalTextContrast() throws {
        for dark in [false, true] {
            let colors = ThemeCatalog.terrazzo.colors(dark: dark)
            for text in [colors.comment, colors.keyword, colors.string, colors.number, colors.type, colors.variable, colors.link] {
                XCTAssertGreaterThanOrEqual(text.contrast(with: colors.editorBackground), 4.5,
                    "Syntax remains readable on the clean editor surface (dark: \(dark))")
            }
            for status in [colors.added, colors.removed, colors.modified] {
                XCTAssertGreaterThanOrEqual(status.contrast(with: colors.card), 4.5)
            }
            XCTAssertGreaterThanOrEqual(colors.onAccent.contrast(with: colors.accent), 4.5)
            let material = try XCTUnwrap(colors.primaryMaterial)
            XCTAssertGreaterThanOrEqual(material.text.contrast(with: material.top), 4.5)
            XCTAssertGreaterThanOrEqual(material.text.contrast(with: material.bottom), 4.5)
            XCTAssertFalse(material.speckles.isEmpty, "interaction particles keep their mineral palette")
        }
    }
}
