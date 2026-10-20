import AppKit
import SwiftUI

/// Where a surface sits, which decides its material. Reading surfaces (editor text, diff rows, terminal) are always
/// solid; glass is kept to the chrome around them.
enum FolmiSurfaceRole {
    /// The project rail: it sits on the window's own glass, so it only adds a faint tint.
    case rail
    /// Secondary navigation inside a card (outline, file list headers).
    case navigation
    /// A card's title bar and tab strips.
    case header
    /// The status bar along the window bottom.
    case status
    /// Floating controls over text: the format bar, the `/` menu, code tools.
    case popover
}

private struct FolmiGlassKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// The user's 玻璃材质 choice. Reduce Transparency and Increase Contrast override it.
    var folmiGlass: Bool {
        get { self[FolmiGlassKey.self] }
        set { self[FolmiGlassKey.self] = newValue }
    }
}

/// Glass in the spirit of Solid Glass: neutral planes, a light top edge, a hairline outline and a soft shadow, with
/// real blur only where something lies behind (the rail over the desktop, floating bars over text). Few effect views,
/// so scrolling and typing do not pay for blur.
struct FolmiSurface: ViewModifier {
    let role: FolmiSurfaceRole
    var cornerRadius: CGFloat = 0
    @Environment(\.folmiTheme) private var theme
    @Environment(\.folmiGlass) private var glassEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    /// Solid fallback replaces the fill as well as dropping the blur, rather than leaving a see-through color.
    private var glass: Bool { theme.usesGlass(requested: glassEnabled, reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased) }
    private var stoneLight: Bool { theme == .terrazzo && colorScheme == .light && contrast != .increased }
    /// Callers give the flat radius; square themes drop it and lifted themes round a little more.
    private var radius: CGFloat {
        guard cornerRadius > 0 else { return 0 }
        if theme.style.isSquare { return 0 }
        if case .lifted = theme.style.shadow { return cornerRadius + 4 }
        return cornerRadius
    }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    func body(content: Content) -> some View {
        content
            .background { fill }
            .overlay { if glass || stoneLight || (role == .popover && (theme.style.isSquare || theme == .terrazzo)) { edge.allowsHitTesting(false) } }
    }

    @ViewBuilder private var fill: some View {
        let base = Color.theme(theme, role == .rail || role == .status ? \.canvas : \.header)
        if stoneLight, role == .navigation || role == .header {
            base.overlay(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                .clipShape(shape)
        } else if theme == .terrazzo, role == .popover {
            base.clipShape(shape)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 4, y: 2)
        } else if !glass {
            base.clipShape(shape)
        } else {
            switch role {
            case .rail, .status:
                // The window backdrop already blurs the desktop; a second effect view would only cost.
                base.opacity(colorScheme == .dark ? 0.22 : 0.18).clipShape(shape)
            case .popover:
                ZStack {
                    if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.regular, in: shape)
                    } else {
                        VisualEffectBackground(material: .popover, blending: .withinWindow)
                    }
                }
                .clipShape(shape)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 12, y: 4)
            case .navigation, .header:
                // Nothing moves behind a fixed bar, so blur would only cost; a faint top-lit gradient reads as glass.
                base.overlay(LinearGradient(colors: [Color.white.opacity(colorScheme == .dark ? 0.035 : 0.4), .clear],
                                            startPoint: .top, endPoint: .bottom))
                    .clipShape(shape)
            }
        }
    }

    /// A light top edge and a hairline outline, aligned to the pixel grid by stroking inside the shape.
    @ViewBuilder private var edge: some View {
        let highlight = Color.white.opacity(colorScheme == .dark ? 0.09 : 0.65)
        switch role {
        case .popover:
            if theme.style.isSquare || theme == .terrazzo {
                shape.strokeBorder(.themed(.border), lineWidth: theme.style.borderWidth)
            } else {
                shape.strokeBorder(LinearGradient(colors: [highlight, Color.primary.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                                   lineWidth: 1)
            }
        case .rail:
            HStack { Spacer(); Rectangle().fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)).frame(width: 1) }
        case .status:
            VStack(spacing: 0) { Rectangle().fill(Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.07)).frame(height: 1); Spacer(minLength: 0) }
        case .navigation, .header:
            VStack(spacing: 0) {
                Rectangle().fill(highlight).frame(height: 1)
                Spacer(minLength: 0)
            }
        }
    }
}

extension View {
    func folmiSurface(_ role: FolmiSurfaceRole, cornerRadius: CGFloat = 0) -> some View {
        modifier(FolmiSurface(role: role, cornerRadius: cornerRadius))
    }
}

/// A card's body: solid reading color, an edge and a lift in the theme's style (soft blur, hard pixel offset, or a
/// deeper lifted blur with a lit top edge).
struct FolmiCardShape: ViewModifier {
    let focused: Bool
    @Environment(\.folmiTheme) private var theme
    @Environment(\.folmiGlass) private var glassEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let style = theme.style
        let shape = RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous)
        let glass = theme.usesGlass(requested: glassEnabled, reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
        let dark = colorScheme == .dark
        content
            .background(Color.theme(theme, \.card))
            .clipShape(shape)
            .overlay {
                ZStack {
                    if !style.borderless || contrast == .increased {
                        shape.strokeBorder(.themed(.border), lineWidth: min(1, style.borderWidth))
                    }
                    if focused {
                        // Focus belongs to the header; the reading surface keeps a quiet boundary.
                        FocusLine(sweep: style.focusSweep && !reduceMotion, style: .themed(.accent, opacity: style.focusLineOpacity))
                            .frame(height: style.focusLineWidth).frame(maxHeight: .infinity, alignment: .top)
                            .clipShape(shape)
                    }
                    if !focused, !style.isSquare, glass || isLifted(style) || (theme == .terrazzo && !dark && contrast != .increased) {
                        // The inner top highlight of a solid slab.
                        shape.inset(by: 1).strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(dark ? (isLifted(style) ? 0.07 : 0.06) : 0.5), .clear],
                                           startPoint: .top, endPoint: .center), lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)
                .animation(reduceMotion ? nil : Motion.state, value: focused)
            }
            // The shadow is drawn from the shape alone, never from the card's content, so it stays cheap.
            .background {
                switch style.shadow {
                case .none:
                    EmptyView()
                case .warm:
                    shape.fill(Color.theme(theme, \.card))
                        .shadow(color: dark ? .black.opacity(0.35) : Color(red: 0.47, green: 0.31, blue: 0.08).opacity(0.10),
                                radius: dark ? 6 : 14, y: dark ? 2 : 5)
                case let .hard(offset):
                    shape.fill(.themed(.border)).offset(x: offset, y: offset)
                case .lifted:
                    shape.fill(Color.theme(theme, \.card))
                        .shadow(color: .black.opacity(dark ? 0.55 : 0.12), radius: 16, y: 8)
                case .soft:
                    if theme == .terrazzo {
                        shape.fill(Color.theme(theme, \.card))
                            .shadow(color: .black.opacity(dark ? 0.22 : 0.12), radius: dark ? 3 : 16, y: dark ? 1 : 8)
                    } else if glass {
                        shape.fill(Color.theme(theme, \.card))
                            .shadow(color: .black.opacity(dark ? 0.3 : 0.08), radius: 6, y: 2)
                    }
                }
            }
    }

    private func isLifted(_ style: ThemeStyle) -> Bool { if case .lifted = style.shadow { return true } else { return false } }
}

/// The focused card's top line. With `sweep` it draws in from the leading edge each time the card takes focus.
private struct FocusLine: View {
    let sweep: Bool
    let style: ThemeColor
    @State private var drawn = false
    var body: some View {
        GeometryReader { geometry in
            Rectangle().fill(style)
                .frame(width: sweep && !drawn ? 0 : geometry.size.width)
        }
        .onAppear {
            guard sweep else { return }
            withAnimation(Motion.resolved(.easeOut(duration: 0.22), reduceMotion: Motion.systemReducesMotion)) { drawn = true }
        }
    }
}

/// The whole window's floor. With glass on it is one behind-window blur of the desktop under a thin theme tint; the
/// cards sit on it as solid slabs with gaps between them, so the hierarchy reads as floor → block → floating bar.
/// One effect view for the window, none per card, so scrolling and typing never pay for blur.
struct WindowBackdrop: View {
    let theme: FolmiTheme
    let glass: Bool
    /// How much of the theme's floor color lies over the blurred desktop.
    static func glassTint(dark: Bool) -> Double { dark ? 0.88 : 0.84 }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let canvas = Color.theme(theme, \.canvas)
        Group {
            if theme.usesGlass(requested: glass, reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased) {
                // The theme's own floor color carries the window, with just enough desktop showing through to feel
                // like glass. A thin tint let the neutral system material (or the wallpaper) win, so the floor read
                // grey while the cards on it were tinted.
                ZStack {
                    VisualEffectBackground(material: .underWindowBackground, blending: .behindWindow)
                    canvas.opacity(Self.glassTint(dark: colorScheme == .dark))
                    ThemeFloorTexture(theme: theme)
                }
            } else {
                ZStack { canvas; ThemeFloorTexture(theme: theme) }
            }
        }
        .ignoresSafeArea()
    }
}

/// NSVisualEffectView for SwiftUI backgrounds. It never takes clicks, so gestures on the content above still work.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassthroughEffectView()
        view.state = .followsWindowActiveState
        view.material = material
        view.blendingMode = blending
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
        if view.blendingMode != blending { view.blendingMode = blending }
    }
    private final class PassthroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
