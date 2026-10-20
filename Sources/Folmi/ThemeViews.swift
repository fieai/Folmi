import AppKit
import SwiftUI

/// A theme color as a SwiftUI style. It resolves from the environment's theme and color scheme, so a view picks
/// `.themed(.accent)` without holding the theme itself and updates when either changes.
struct ThemeColor: ShapeStyle {
    let token: ThemeToken
    var opacity: Double = 1
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.folmiTheme.definition.colors(dark: environment.colorScheme == .dark)[token].opacity(opacity).color
    }
}

extension ShapeStyle where Self == ThemeColor {
    static func themed(_ token: ThemeToken, opacity: Double = 1) -> ThemeColor { ThemeColor(token: token, opacity: opacity) }
}

/// A background in the theme's corner radius for its role (rows, controls, cards).
private struct ThemedBackground<S: ShapeStyle>: ViewModifier {
    let style: S
    let corner: ThemeCorner
    @Environment(\.folmiTheme) private var theme
    func body(content: Content) -> some View {
        content.background(style, in: RoundedRectangle(cornerRadius: theme.style.radius(corner), style: .continuous))
    }
}

extension View {
    func themedBackground<S: ShapeStyle>(_ style: S, _ corner: ThemeCorner = .row) -> some View {
        modifier(ThemedBackground(style: style, corner: corner))
    }
}

/// A native button still owns activation (including keyboard and cancelled drags). 石墨 takes its stone material,
/// 琥珀 a clay capsule, 锌莓 a square-cornered key, 像素 a hard edge; the rest the accent in the control corner.
struct FolmiProminentButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentAction(configuration: configuration)
    }

    private struct ProminentAction: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @Environment(\.folmiTheme) private var theme

        var body: some View {
            // Stone grains are kept for finished work (a commit, a review); a plain press stays quiet.
            if theme == .terrazzo {
                Button(configuration).buttonStyle(TerrazzoButtonStyle(prominent: true))
            } else {
                Button(configuration).buttonStyle(StandardProminentButtonStyle())
            }
        }
    }
}

/// Existing flat and pixel appearance, kept separate from the 石墨 material.
private struct StandardProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentLabel(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct ProminentLabel<Label: View>: View {
        let label: Label
        let pressed: Bool
        @Environment(\.folmiTheme) private var theme
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var colors: ThemeColors { theme.definition.colors(dark: colorScheme == .dark) }
        private var small: Bool { controlSize == .small || controlSize == .mini }
        private var clay: Bool { theme.style.prominent == .clay }
        private var hard: CGFloat { if case let .hard(offset) = theme.style.shadow { return offset } else { return 0 } }
        /// The clay edge: a darker band under the face that the button sinks onto while pressed.
        private var lip: CGFloat { clay && enabled ? (small ? 2 : 3) : 0 }
        private var shape: AnyShape { theme.style.prominentShape }
        /// Disabled reads as plainly unavailable: a neutral fill, not a faded accent or a grainy slab.
        private var face: Color {
            enabled ? colors.accent.color.opacity(pressed && !clay ? 0.85 : 1) : colors.selectedFill.color
        }
        private var sink: CGFloat {
            if lip > 0 { return pressed ? lip - 1 : 0 }
            return hard > 0 && pressed ? hard - 1 : 0
        }

        var body: some View {
            let shape = shape, lip = lip, hard = hard
            let text = (enabled ? (colors.primaryMaterial?.text ?? colors.onAccent) : colors.tertiaryText).color
            label
                .themedFont(.system(size: small ? 11.5 : 12.5, weight: .semibold), points: small ? 11.5 : 12.5)
                .foregroundStyle(text)
                .padding(.horizontal, small ? 9 : (clay ? 14 : 12)).padding(.vertical, small ? 3 : 5)
                .background { shape.fill(face) }
                // Only the square pixel theme has a hard shadow, so its edge is an inset rectangle.
                .overlay { if hard > 0 { Rectangle().strokeBorder(colors.border.color, lineWidth: theme.style.borderWidth) } }
                .background { edge(shape) }
                .offset(x: hard > 0 ? sink : 0, y: sink)
                .scaleEffect(pressed && hard == 0 && lip == 0 && !reduceMotion ? 0.97 : 1)
                .padding(.bottom, lip)
                .animation(reduceMotion ? nil : Motion.press, value: pressed)
                .contentShape(shape)
                .pointerCursor()
        }

        /// What the face rests on: the clay lip, or the pixel theme's hard shadow.
        @ViewBuilder private func edge(_ shape: AnyShape) -> some View {
            if lip > 0 {
                shape.fill(colors.accent.color).overlay { shape.fill(Color.black.opacity(0.2)) }
                    .offset(y: pressed ? 1 : lip)
            } else if hard > 0, !pressed, enabled {
                shape.fill(colors.border.color).offset(x: hard - 1, y: hard - 1)
            }
        }
    }
}

extension PrimitiveButtonStyle where Self == FolmiProminentButtonStyle {
    static var folmiProminent: FolmiProminentButtonStyle { FolmiProminentButtonStyle() }
}

/// Opaque, matte controls. The face has no static speckles or glossy highlight; motion is a short downward press.
struct TerrazzoButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        Face(label: configuration.label, pressed: configuration.isPressed,
             destructive: configuration.role == .destructive, prominent: prominent)
    }

    private struct Face<Label: View>: View {
        let label: Label
        let pressed: Bool
        let destructive: Bool
        let prominent: Bool
        @Environment(\.folmiTheme) private var theme
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            let colors = theme.definition.colors(dark: colorScheme == .dark)
            let small = controlSize == .small || controlSize == .mini
            let shape = RoundedRectangle(cornerRadius: theme.style.controlRadius, style: .continuous)
            let face = prominent ? (colors.primaryMaterial?.top ?? colors.accent) : colors.card
            let ink = prominent ? (colors.primaryMaterial?.text ?? colors.onAccent) : (destructive ? colors.removed : colors.foreground)
            label
                .themedFont(.system(size: small ? 11.5 : 12.5, weight: prominent ? .semibold : .regular), points: small ? 11.5 : 12.5)
                .foregroundStyle((enabled ? ink : colors.tertiaryText).color)
                .padding(.horizontal, small ? 9 : 12)
                .padding(.vertical, small ? 3 : 5)
                .background {
                    shape.fill((enabled ? face : colors.selectedFill).color)
                        .overlay { shape.fill(ink.color.opacity(enabled && (hovered || pressed) ? (pressed ? 0.08 : 0.035) : 0)) }
                        .shadow(color: .black.opacity(enabled ? (colorScheme == .dark ? 0.22 : 0.10) : 0),
                                radius: pressed ? 0.5 : 2, y: pressed ? 0 : 1.5)
                }
                .overlay { shape.strokeBorder(colors.border.color, lineWidth: 1) }
                .offset(y: pressed && enabled && !reduceMotion ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: pressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .contentShape(shape)
                .onHover { hovered = $0 }
                .pointerCursor()
        }
    }
}

/// A thin progress bar in the theme's progress colors: a gradient, or hard steps for pixel.
struct ThemeProgressBar: View {
    let fraction: Double
    var width: CGFloat = 64
    @Environment(\.folmiTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = theme.definition.colors(dark: colorScheme == .dark)
        let style = theme.style
        let stops = (colors.progress ?? [colors.accent]).map(\.color)
        let height: CGFloat = style.isSquare ? 6 : 4
        let shape = RoundedRectangle(cornerRadius: style.isSquare ? 0 : height / 2, style: .continuous)
        let filled = max(0, min(1, fraction.isFinite ? fraction : 0)) * width
        ZStack(alignment: .leading) {
            shape.fill(colors.selectedFill.color)
            Group {
                if style.steppedProgress, stops.count > 1 {
                    HStack(spacing: 0) { ForEach(stops.indices, id: \.self) { stops[$0] } }.frame(width: width)
                } else {
                    LinearGradient(colors: stops.count > 1 ? stops : [stops[0], stops[0]], startPoint: .leading, endPoint: .trailing).frame(width: width)
                }
            }
            .frame(width: filled, alignment: .leading)
            .clipShape(shape)
        }
        .frame(width: width, height: height)
        .overlay { if style.isSquare { shape.strokeBorder(colors.border.color, lineWidth: 1) } }
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction.isFinite ? fraction : 0) * 100))%")
    }
}

/// Optional floor decoration: a palette glow or a fine checker (像素). Dark matte stone leaves both off.
struct ThemeFloorTexture: View {
    let theme: FolmiTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = theme.definition.colors(dark: colorScheme == .dark)
        ZStack {
            if let glow = colors.backdropGlow {
                RadialGradient(colors: [glow.color, glow.opacity(0).color], center: UnitPoint(x: 0.5, y: -0.1),
                               startRadius: 0, endRadius: 900)
            }
            if theme.style.dither {
                // Faint: the cards above it carry the text; the dither is only a hint of the floor.
                Image(nsImage: Self.checker(colors.foreground.opacity(colorScheme == .dark ? 0.035 : 0.04).nsColor))
                    .resizable(resizingMode: .tile)
            }
        }
        .allowsHitTesting(false)
    }

    /// A 4×4 pt tile with two 2 pt dots: the classic 50% dither.
    private static func checker(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 4, height: 4), flipped: false) { _ in
            color.setFill()
            NSRect(x: 0, y: 0, width: 2, height: 2).fill()
            NSRect(x: 2, y: 2, width: 2, height: 2).fill()
            return true
        }
    }
}

/// A sheet's content settles in: a short fade and a slight rise in scale over the native sheet slide. Off with
/// Reduce Motion.
private struct SheetEntrance: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            // Sheets sit outside the window content, so they take the themed default buttons here.
            .buttonStyle(ThemedDefaultButtonStyle())
            .opacity(shown || reduceMotion ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.97, anchor: .top)
            .onAppear {
                guard !reduceMotion else { return }
                withMotion(Motion.settle) { shown = true }
            }
    }
}

extension View {
    func sheetEntrance() -> some View { modifier(SheetEntrance()) }
}

/// Closes the window's sheet when the user clicks the window outside it. AppKit drops clicks on a window that has a
/// sheet attached; a local monitor still sees them first.
struct SheetOutsideClick: NSViewRepresentable {
    let dismiss: () -> Void
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.dismiss = dismiss }

    final class MonitorView: NSView {
        var dismiss: (() -> Void)?
        nonisolated(unsafe) private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      let sheet = window.attachedSheet, sheet.isVisible else { return event }
                // Open/save panels and alerts end their own way.
                guard !(sheet is NSSavePanel), !sheet.className.contains("Alert") else { return event }
                MainActor.assumeIsolated { self.dismiss?() }
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A two-or-more-way switch drawn in the theme instead of the system's accent-filled segmented control: a neutral
/// track with the chosen segment lifted on a card-colored fill that slides between choices. The accent stays free
/// for the primary action.
struct ThemedSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var fillsWidth = false
    @Namespace private var fill
    @Environment(\.folmiTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let small = controlSize == .small || controlSize == .mini
        HStack(spacing: 1) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .themedFont(.system(size: small ? 11.5 : 12.5, weight: selected ? .semibold : .regular), points: small ? 11.5 : 12.5)
                        .foregroundStyle(ThemeColor(token: selected ? .foreground : .secondaryText))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .padding(.horizontal, small ? 8 : 10)
                        .frame(maxWidth: fillsWidth ? .infinity : nil)
                        .frame(height: small ? 20 : 24)
                        .background {
                            if selected { SegmentThumb().matchedGeometryEffect(id: "fill", in: fill) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .segmentTrack()
        .opacity(enabled ? 1 : 0.5)
        .motion(Motion.state, value: selection)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
    }
}

/// Buttons without a style of their own: the system push button, or under square themes (像素) a key with a hard
/// edge and an offset shadow that presses down. Applied to the window's content, not its toolbar or sheets.
struct ThemedDefaultButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ThemedDefaultButton(configuration: configuration) }

    private struct ThemedDefaultButton: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @Environment(\.folmiTheme) private var theme
        var body: some View {
            if theme.style.isSquare {
                Button(configuration).buttonStyle(PixelKeyButtonStyle())
            } else if theme == .terrazzo {
                Button(configuration).buttonStyle(TerrazzoButtonStyle())
            } else {
                Button(configuration).buttonStyle(.automatic).pointerCursor()
            }
        }
    }
}

/// A secondary 像素 key: card fill, the theme's edge, and a solid shadow it sinks into while pressed.
struct PixelKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PixelKey(label: configuration.label, pressed: configuration.isPressed, destructive: configuration.role == .destructive)
    }

    private struct PixelKey<Label: View>: View {
        let label: Label
        let pressed: Bool
        let destructive: Bool
        @Environment(\.folmiTheme) private var theme
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.controlSize) private var controlSize
        var body: some View {
            let colors = theme.definition.colors(dark: colorScheme == .dark)
            let small = controlSize == .small || controlSize == .mini
            // The shadow stays put while the key sinks onto it.
            let sunk: CGFloat = pressed ? 2 : 0
            label
                .themedFont(.system(size: small ? 11 : 12), points: small ? 11 : 12)
                .foregroundStyle((enabled ? (destructive ? colors.removed : colors.foreground) : colors.tertiaryText).color)
                .lineLimit(1)
                .padding(.horizontal, small ? 7 : 10)
                // As tall as a ThemedSegmented option beside it, so the text never touches the edge.
                .frame(minHeight: small ? 20 : 24)
                .background(pressed ? colors.hover.color : colors.card.color)
                .overlay { Rectangle().strokeBorder(colors.border.color.opacity(enabled ? 1 : 0.4), lineWidth: 1.5) }
                .background { if enabled { Rectangle().fill(colors.border.color).offset(x: 2 - sunk, y: 2 - sunk) } }
                .offset(x: sunk, y: sunk)
                .padding(.trailing, 2).padding(.bottom, 2)
                .contentShape(Rectangle())
                .pointerCursor()
        }
    }
}

/// Text fields: the system rounded field, or under square themes a flat card-colored box with the theme's edge.
private struct ThemedTextField: ViewModifier {
    @Environment(\.folmiTheme) private var theme
    func body(content: Content) -> some View {
        if theme.style.isSquare {
            content.textFieldStyle(.plain)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(ThemeColor(token: .card))
                .overlay { Rectangle().strokeBorder(ThemeColor(token: .border), lineWidth: 1.5) }
        } else if theme == .terrazzo {
            content.textFieldStyle(.plain)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .themedBackground(ThemeColor(token: .card), .control)
                .themedEditorFrame()
        } else {
            content.textFieldStyle(.roundedBorder)
        }
    }
}

/// A pill (tag, count, floating bar): a capsule, or a box with the theme's edge under square themes.
private struct ThemedCapsule<S: ShapeStyle>: ViewModifier {
    let fill: S
    let stroke: Bool
    @Environment(\.folmiTheme) private var theme
    func body(content: Content) -> some View {
        if theme.style.isSquare {
            content.background(fill, in: Rectangle())
                .overlay { Rectangle().strokeBorder(ThemeColor(token: .border), lineWidth: 1) }
        } else {
            content.background(fill, in: Capsule())
                .overlay { if stroke { Capsule().strokeBorder(ThemeColor(token: .border)) } }
        }
    }
}

/// A labeled field in a grouped Form. Native everywhere but square themes, where the label stays in the form's
/// label column and only the field gets the boxed look; wrapping the whole row would box the label too.
struct FormTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String?
    var secure = false
    @Environment(\.folmiTheme) private var theme
    var body: some View {
        if theme.style.isSquare {
            LabeledContent(title) { field(label: "").labelsHidden().themedTextField() }
        } else {
            field(label: title)
        }
    }
    @ViewBuilder private func field(label: String) -> some View {
        if secure { SecureField(label, text: $text, prompt: prompt.map { Text($0) }) }
        else { TextField(label, text: $text, prompt: prompt.map { Text($0) }) }
    }
}

/// The frame around a multi-line editor: the theme's control corner and edge.
private struct ThemedEditorFrame: ViewModifier {
    @Environment(\.folmiTheme) private var theme
    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: theme.style.radius(.control))
            .strokeBorder(ThemeColor(token: .border), lineWidth: theme.style.isSquare ? 1.5 : 1))
    }
}

extension View {
    func themedEditorFrame() -> some View { modifier(ThemedEditorFrame()) }
    func themedTextField() -> some View { modifier(ThemedTextField()) }
    func themedCapsule<S: ShapeStyle>(_ fill: S, stroke: Bool = false) -> some View { modifier(ThemedCapsule(fill: fill, stroke: stroke)) }
}

// MARK: - Tabs

/// The chosen option inside a segmented group (差异 / 编辑, ThemedSegmented): a lifted card-colored thumb, a capsule
/// under 琥珀, or only an accent line under 锌莓. Pixel adds its edge.
struct SegmentThumb: View {
    @Environment(\.folmiTheme) private var theme
    var body: some View {
        let style = theme.style
        switch style.tabs {
        case .underline:
            Rectangle().fill(.themed(.accent)).frame(height: 2).frame(maxHeight: .infinity, alignment: .bottom)
        case .capsule:
            Capsule().fill(.themed(.card)).shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
        case .fill, .segmented:
            Color.clear.themedBackground(ThemeColor(token: .card), .control)
                .overlay { if style.isSquare { Rectangle().strokeBorder(ThemeColor(token: .border), lineWidth: style.borderWidth) } }
                .shadow(color: .black.opacity(style.isSquare ? 0 : (style.tabs == .segmented ? 0.14 : 0.08)), radius: 1, y: 0.5)
        }
    }
}

/// The neutral track behind a segmented group; 锌莓 draws none, its options are only underlined.
private struct SegmentTrack: ViewModifier {
    @Environment(\.folmiTheme) private var theme
    func body(content: Content) -> some View {
        switch theme.style.tabs {
        case .underline: content
        case .capsule: content.padding(2).background(ThemeColor(token: .hover), in: Capsule())
        case .fill, .segmented: content.padding(2).themedBackground(ThemeColor(token: .hover), .control)
        }
    }
}

/// A card header tab's own background: a fill or capsule behind the chosen tab, an accent line along the header's
/// bottom (锌莓), or a lifted thumb inside the group's track (石墨).
struct TabBackground: View {
    let selected: Bool
    var hovering = false
    @Environment(\.folmiTheme) private var theme
    var body: some View {
        switch theme.style.tabs {
        case .fill:
            Color.clear.themedBackground(ThemeColor(token: selected ? .selectedFill : .hover, opacity: selected || hovering ? 1 : 0), .control)
        case .capsule:
            Capsule().fill(ThemeColor(token: selected ? .selectedFill : .hover, opacity: selected || hovering ? 1 : 0))
        case .underline:
            Rectangle().fill(.themed(.accent, opacity: selected ? 1 : 0)).frame(height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        case .segmented:
            if selected { SegmentThumb() }
            else { Color.clear.themedBackground(ThemeColor(token: .hover, opacity: hovering ? 1 : 0), .control) }
        }
    }
}

/// Card header tabs that belong together (改动 / 文件, terminal tabs): under 石墨 they share a segmented track.
struct PaneTabGroup<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.folmiTheme) private var theme
    var body: some View {
        if theme.style.tabs == .segmented {
            HStack(spacing: 1) { content }.modifier(SegmentTrack())
        } else {
            content
        }
    }
}

extension View {
    func segmentTrack() -> some View { modifier(SegmentTrack()) }
}
