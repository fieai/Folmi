import AppKit
import CoreText
import SwiftUI

/// The 像素 theme's typeface: Fusion Pixel 12px (monospaced, Simplified Chinese build; OFL-1.1, see licenses/FusionPixel).
/// Registered for this process the first time the theme asks for it. A bitmap-style font is only sharp at whole
/// multiples of its 12 px grid, so every size snaps to 12 or 24.
enum PixelFont {
    static let postScriptName = "Fusion-Pixel-12px-Mono-zh-Hans-Regular"
    static let fileName = "fusion-pixel-12px-monospaced-zh_hans.otf"

    /// True once the font is registered (or was already installed); false when the file is missing.
    @MainActor static let isAvailable: Bool = {
        if NSFont(name: postScriptName, size: 12) != nil { return true }
        guard let url = fileURL else {
            AppLog.logger.error("像素字体：资源包里找不到 \(fileName, privacy: .public)")
            return false
        }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !registered, let error {
            AppLog.failure("像素字体：注册 \(url.path) 失败", error.takeRetainedValue())
        }
        return registered && NSFont(name: postScriptName, size: 12) != nil
    }()

    static var fileURL: URL? { AppResources.folder("Fonts")?.appendingPathComponent(fileName) }

    /// 12 for everything up to title size, 24 above.
    static func size(for points: CGFloat) -> CGFloat { points >= 19 ? 24 : 12 }
    static func font(_ points: CGFloat) -> Font { .custom(postScriptName, fixedSize: size(for: points)) }
}

private struct ThemedFont: ViewModifier {
    let system: Font
    let points: CGFloat
    @Environment(\.folmiTheme) private var theme
    func body(content: Content) -> some View {
        content.font(theme.style.pixelFont && PixelFont.isAvailable ? PixelFont.font(points) : system)
    }
}

extension View {
    /// `font(system)` in every theme but 像素, which uses the pixel font at the size `points` snaps to.
    func themedFont(_ system: Font, points: CGFloat) -> some View { modifier(ThemedFont(system: system, points: points)) }
}
