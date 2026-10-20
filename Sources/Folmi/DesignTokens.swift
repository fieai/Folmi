import SwiftUI

// Shared motion and size values. Views pick a named token instead of writing their own duration or spacing, so the
// whole app moves and lines up the same way, and a change here retunes every place at once.

/// Every animation in the app is one of these.
enum Motion {
    /// Hover fills and small pointer feedback.
    static let hover = Animation.easeOut(duration: 0.12)
    /// A button giving under the pointer and coming back.
    static let press = Animation.spring(response: 0.2, dampingFraction: 0.6)
    /// Selection, tab switches, toggles: one state replacing another.
    static let state = Animation.snappy(duration: 0.2)
    /// Something arriving or leaving inside a card: rows, notices, counts.
    static let reveal = Animation.snappy(duration: 0.26)
    /// Cards opening, closing, maximizing.
    static let layout = Animation.smooth(duration: 0.3)
    /// Something landing with weight: a commit, an edge springing back to its limit.
    static let settle = Animation.spring(response: 0.4, dampingFraction: 0.68)
    /// Keeping a list's selection in view while arrowing through it.
    static let scroll = Animation.easeOut(duration: 0.1)
    /// A slow breathing pulse for work in progress.
    static let pulse = Animation.easeInOut(duration: 0.9).repeatForever()

    /// The animation, or none when the person asked the system to reduce motion.
    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? { reduceMotion ? nil : animation }
    static var systemReducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Sizes the cards and controls share.
enum Metrics {
    /// The gap between cards, which doubles as their resize handle.
    static let paneGap: CGFloat = 10
    /// A card's title strip.
    static let paneHeader: CGFloat = 38
    /// Square icon buttons in title strips and toolbars.
    static let iconButton: CGFloat = 24
    static let iconSize: CGFloat = 11
    /// Inner padding of a card's own content.
    static let contentInset: CGFloat = 10
    /// How far a pressed control shrinks, and a pressed full-width row.
    static let pressScale: CGFloat = 0.94
    static let rowPressScale: CGFloat = 0.985
}

private struct MotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View { content.animation(reduceMotion ? nil : animation, value: value) }
}

extension View {
    /// `.animation(_:value:)` that stays still when Reduce Motion is on.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }
}

/// Runs a change with a motion token, or without animation under Reduce Motion.
@MainActor
func withMotion<Result>(_ animation: Animation, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Motion.resolved(animation, reduceMotion: Motion.systemReducesMotion), body)
}

/// A plain button that answers a click: it gives a little under the pointer and springs back. Square-cornered
/// themes (像素) press down by a pixel instead of shrinking, like a hardware key.
struct PressableButtonStyle: ButtonStyle {
    enum Kind { case control, row }
    var kind: Kind = .control

    func makeBody(configuration: Configuration) -> some View {
        PressableLabel(label: configuration.label, pressed: configuration.isPressed, kind: kind)
    }

    private struct PressableLabel<Label: View>: View {
        let label: Label
        let pressed: Bool
        let kind: Kind
        @Environment(\.folmiTheme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            let pixel = theme.style.isSquare
            let scale = kind == .row ? Metrics.rowPressScale : Metrics.pressScale
            label
                .opacity(pressed ? 0.78 : 1)
                .scaleEffect(pressed && !pixel && !reduceMotion ? scale : 1)
                .offset(x: pressed && pixel ? 1 : 0, y: pressed && pixel ? 1 : 0)
                .animation(reduceMotion ? nil : Motion.press, value: pressed)
                .pointerCursor()
        }
    }
}

/// The pointing hand over an enabled button, so a click target reads as one; a disabled button keeps the arrow.
private struct PointerCursor: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in update(inside && enabled) }
            .onChange(of: enabled) { _, now in if !now { update(false) } }
            .onDisappear { update(false) }
    }

    private func update(_ show: Bool) {
        guard show != pushed else { return }
        pushed = show
        if show { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }
}

extension View {
    func pointerCursor() -> some View { modifier(PointerCursor()) }
}

/// A text link in the theme's own link color. The system `.link` style always draws in the system blue, which
/// ignored every theme (石墨 included) that picks another link color.
struct ThemedLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ThemedLink(configuration: configuration) }

    private struct ThemedLink: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? AnyShapeStyle(ThemeColor(token: .link)) : AnyShapeStyle(.tertiary))
                .underline(hovering && enabled)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .pointerCursor()
        }
    }
}

extension ButtonStyle where Self == ThemedLinkButtonStyle {
    static var themedLink: ThemedLinkButtonStyle { ThemedLinkButtonStyle() }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
    static var pressableRow: PressableButtonStyle { PressableButtonStyle(kind: .row) }
}
