import SwiftUI

/// Every theme the app offers, in menu order. To add a theme, add one `ThemeDefinition` here: menus, persistence,
/// the editor, the terminal and the Markdown reader all read from this list.
enum ThemeCatalog {
    static let all: [ThemeDefinition] = [indigo, zinc, pixel, terrazzo]
    /// Used for a fresh install and for any saved id that no longer exists.
    static var fallback: ThemeDefinition { all[0] }
    /// Ids from earlier versions (原生 / One / 纸墨), read as the fallback instead of being dropped as unknown.
    static let retiredIDs: Set<String> = ["native", "one", "paper"]

    static func definition(_ id: String) -> ThemeDefinition? { all.first { $0.id == id } }

    // Keep the saved id so existing 靛石 selections receive the Folmi palette without a preference migration.
    static let indigo = ThemeDefinition(
        id: "indigo", title: "琥珀", detail: "Folmi 图标同款琥珀黄配炭黑，圆润温暖，小精灵在状态栏陪你干活",
        style: .amber,
        light: ThemeColors(
            canvas: 0xF0EFEC, card: 0xFFFEFA, header: 0xF7F5EF, editorBackground: 0xFFFEFA, gutter: 0xFFFEFA,
            border: ThemeRGB(0x222429, 0.10), foreground: 0x222429, secondaryText: 0x67665F, tertiaryText: 0x8A887F,
            hover: ThemeRGB(0xE9AA47, 0.08), selectedFill: ThemeRGB(0xE9AA47, 0.16),
            accent: 0xE9AA47, onAccent: 0x222429, added: 0x1F8A5B, removed: 0xC2413A, modified: 0xB7791F,
            comment: 0x8A887F, keyword: 0x8A5A14, string: 0x2D7A4F, number: 0x9A5714, type: 0x745D3A, variable: 0x8A5A14,
            selection: 0xF2D9A6, link: 0x875710),
        dark: ThemeColors(
            canvas: 0x181A1E, card: 0x222429, header: 0x292B30, editorBackground: 0x222429, gutter: 0x222429,
            border: ThemeRGB(0xF2E8D5, 0.09), foreground: 0xEEEDE8, secondaryText: 0xABA9A3, tertiaryText: 0x7A7974,
            hover: ThemeRGB(0xE9AA47, 0.06), selectedFill: ThemeRGB(0xE9AA47, 0.11),
            accent: 0xE9AA47, onAccent: 0x222429, added: 0x5CC28E, removed: 0xEF7D74, modified: 0xE3B04B,
            comment: 0x7A7974, keyword: 0xF2C676, string: 0x8FD19E, number: 0xE7A867, type: 0xD8C1A2, variable: 0xE9AA47,
            selection: 0x594327, link: 0xE9AA47))

    static let zinc = ThemeDefinition(
        id: "zinc", title: "锌莓", detail: "锌灰配莓红，精密紧凑：细线分区、等宽数字，每个文件标出增删行数",
        style: .zinc,
        light: ThemeColors(
            canvas: 0xF0F0F1, card: 0xFFFFFF, header: 0xF7F7F8, editorBackground: 0xFFFFFF, gutter: 0xFFFFFF,
            border: ThemeRGB(0x000000, 0.09), foreground: 0x18181B, secondaryText: 0x5F5F68, tertiaryText: 0x94949C,
            hover: ThemeRGB(0x000000, 0.04), selectedFill: ThemeRGB(0x000000, 0.07),
            accent: 0xB8326A, onAccent: 0xFFFFFF, added: 0x1E8556, removed: 0xC4502A, modified: 0xB07A12,
            comment: 0x94949C, keyword: 0x9C2F8E, string: 0x39803F, number: 0xA35A12, type: 0x2F68B0, variable: 0xB8326A,
            selection: 0xF4D6E2, link: 0xB8326A),
        dark: ThemeColors(
            canvas: 0x0F0F11, card: 0x19191C, header: 0x1F1F23, editorBackground: 0x19191C, gutter: 0x19191C,
            border: ThemeRGB(0xFFFFFF, 0.08), foreground: 0xECECEE, secondaryText: 0xA1A1AA, tertiaryText: 0x6B6B74,
            hover: ThemeRGB(0xFFFFFF, 0.04), selectedFill: ThemeRGB(0xFFFFFF, 0.08),
            accent: 0xF06A9E, onAccent: 0x2A0A17, added: 0x5FC48D, removed: 0xF0956C, modified: 0xE2B34E,
            comment: 0x6B6B74, keyword: 0xE38BD6, string: 0x93D49A, number: 0xEDAA6A, type: 0x82B4F2, variable: 0xF06A9E,
            selection: 0x4A2635, link: 0xF06A9E))

    /// Bright, warm primaries with a quiet reading surface. Coin gold marks only what still waits for review (M marks,
    /// the review progress); sky blue is navigation, selection and the primary action; red stays for deletions and
    /// green for additions. Dark keeps the same roles on a neutral floor, with light edges over a black step shadow.
    static let pixel = ThemeDefinition(
        id: "pixel", title: "像素", detail: "方角、硬描边、错位投影；暖红金黄配天空蓝，金黄只标待验收，代码区保持安静",
        style: .pixel,
        light: ThemeColors(
            canvas: 0xE6EEF8, card: 0xFFFFFF, header: 0xF5F7FA, editorBackground: 0xFFFFFF, gutter: 0xF5F7FA,
            border: 0x242A35, foreground: 0x242A35, secondaryText: 0x4A5568, tertiaryText: 0x687387,
            hover: 0xEEF2F7, selectedFill: 0xDDEBFF,
            accent: 0x1B6CC4, onAccent: 0xFFFFFF, added: 0x167A37, removed: 0xC8261C, modified: 0x8A6100,
            comment: 0x7C879A, keyword: 0x7A44B8, string: 0x1E8040, number: 0xC2410C, type: 0x0E7C86, variable: 0x1B6CC4,
            selection: 0xFFE7A0, link: 0x1B6CC4, modifiedMark: 0xFFC629, progress: [0x2CAD55, 0xFFC629, 0xE5352B]),
        dark: ThemeColors(
            canvas: 0x0F1218, card: 0x202329, header: 0x272B33, editorBackground: 0x202329, gutter: 0x1C1F25,
            border: 0x737E90, foreground: 0xE9EDF5, secondaryText: 0xA5AFBF, tertiaryText: 0x7C8799,
            hover: 0x2A2F38, selectedFill: 0x22324A,
            accent: 0x5BB2FF, onAccent: 0x0F1218, added: 0x5CCE77, removed: 0xFF6A5C, modified: 0xF2C54B,
            comment: 0x7C8799, keyword: 0xC6A1EF, string: 0x86D99A, number: 0xFFB347, type: 0x5FD4D4, variable: 0x8CC8FF,
            selection: 0x2A3D5E, link: 0x8CC8FF, progress: [0x5CCE77, 0xF2C54B, 0xFF6A5C], shadow: 0x000000))

    /// Graphite: no hue of its own. Ink and stone carry the chrome; the mineral grains on the primary button are the
    /// only color, and a little verdigris marks links. Leaves sky blue and coin gold to 像素 and amber to 琥珀. Saved under its first name, terrazzo.
    static let terrazzo = ThemeDefinition(
        id: "terrazzo", title: "石墨", detail: "石墨与石灰，不带主色：同心圆角、不描边、Finder 式选中；颜色只在矿物颗粒里",
        style: .terrazzo,
        light: ThemeColors(
            canvas: 0xE7E9EB, card: 0xF9FAFA, header: 0xF9FAFA, editorBackground: 0xFFFFFF, gutter: 0xFFFFFF,
            border: ThemeRGB(0x23272D, 0.09), foreground: 0x15181C, secondaryText: 0x575D66, tertiaryText: 0x5F656E,
            hover: ThemeRGB(0x23272D, 0.045), selectedFill: ThemeRGB(0x23272D, 0.07),
            accent: 0x32363D, onAccent: 0xFFFFFF, added: 0x18764D, removed: 0xC0392F, modified: 0x8D6207,
            comment: 0x5F656E, keyword: 0x7A3FD1, string: 0x4F7C1E, number: 0x9E5E00, type: 0x0C778A, variable: 0x226F6B,
            selection: 0xD6E4E2, link: 0x226F6B,
            primaryMaterial: ThemeMaterial(top: 0x3A3E45, bottom: 0x1B1D21, text: 0xF4F5F6,
                                           speckles: [0x6FD3CA, 0xE2A9C0, 0xD9DEE5, 0x8BDCE6, 0xB9A4AF, 0xF0B9CF, 0x9AA3AE]),
            backdropGlow: 0xFFFFFF,
            progress: [0x20B2A6, 0x7CC242, 0xE8B23A, 0xE8772E]),
        dark: ThemeColors(
            canvas: 0x1A1B1D, card: 0x25272A, header: 0x2A2C2F, editorBackground: 0x212325, gutter: 0x212325,
            border: ThemeRGB(0xFFFFFF, 0.12), foreground: 0xE8E8E6, secondaryText: 0xB3B4B1, tertiaryText: 0x9C9D9A,
            hover: ThemeRGB(0xFFFFFF, 0.06), selectedFill: ThemeRGB(0xFFFFFF, 0.11),
            accent: 0xDDDCD8, onAccent: 0x1D1F22, added: 0x8FC79F, removed: 0xE89B90, modified: 0xD9AE62,
            comment: 0x9C9D9A, keyword: 0xC9A3D4, string: 0xA7C79A, number: 0xD9AE62, type: 0x8CC5C0, variable: 0xD8D6CF,
            selection: 0x37494A, link: 0x74C7BF,
            primaryMaterial: ThemeMaterial(top: 0xE6E5E1, bottom: 0xD3D2CD, text: 0x23262A,
                                           speckles: [0x2F9A90, 0xC0718F, 0x5E636A, 0x3E9BAA, 0x8C7A86]),
            progress: [0x74C7BF, 0xA7C79A]))
}
