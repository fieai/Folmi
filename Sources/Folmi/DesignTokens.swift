import SwiftUI

// Shared motion and size values. Views pick a named token instead of writing their own duration or spacing, so the
// whole app moves and lines up the same way, and a change here retunes every place at once.

/// Shared timing for feedback, content changes and deliberate changes to the layout.
enum Motion {
    static let hoverDuration = 0.12
    static let hover = Animation.easeOut(duration: hoverDuration)
    static let press = Animation.smooth(duration: 0.14)
    static let state = Animation.smooth(duration: 0.16)
    static let reveal = Animation.smooth(duration: 0.20)
    static let layout = Animation.smooth(duration: 0.24)
    /// The short dissolve used for feedback that can also play under Reduce Motion.
    static let fade = Animation.easeOut(duration: 0.10)
    /// Keeping a list's selection in view while arrowing through it.
    static let scroll = Animation.easeOut(duration: 0.1)

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
    static let pressScale: CGFloat = 0.98
    static let rowPressScale: CGFloat = 0.99
}

private struct MotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    let fadesUnderReduceMotion: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? (fadesUnderReduceMotion ? Motion.fade : nil) : animation, value: value)
    }
}

private struct MotionContent<Value: Equatable>: ViewModifier {
    let value: Value
    let transition: ContentTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : transition)
            .dissolve(value: value, animation: Motion.state)
    }
}

extension View {
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value, fadesUnderReduceMotion: false))
    }

    /// Use on leaves whose feedback changes only opacity, fill or content.
    func dissolve<Value: Equatable>(value: Value, animation: Animation = Motion.reveal) -> some View {
        modifier(MotionAnimation(animation: animation, value: value, fadesUnderReduceMotion: true))
    }

    func motionContent<Value: Equatable>(_ value: Value, transition: ContentTransition = .opacity) -> some View {
        modifier(MotionContent(value: value, transition: transition))
    }
}

/// Runs a change with a motion token, or without animation under Reduce Motion.
@MainActor
func withMotion<Result>(_ animation: Animation, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Motion.resolved(animation, reduceMotion: Motion.systemReducesMotion), body)
}

/// A plain button that answers a click. In the pixel theme it presses down like a hardware key.
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
                .opacity(pressed ? 0.86 : 1)
                .scaleEffect(pressed && !pixel && !reduceMotion ? scale : 1)
                .offset(x: pressed && pixel && !reduceMotion ? 1 : 0, y: pressed && pixel && !reduceMotion ? 1 : 0)
                .dissolve(value: pressed, animation: Motion.press)
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
                .opacity(configuration.isPressed ? 0.86 : 1)
                .dissolve(value: configuration.isPressed, animation: Motion.press)
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
