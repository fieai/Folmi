import AppKit
import FolmiCore
import SwiftUI

// MARK: - List selection drawn by the theme

/// Turns off the system's selection highlight in the enclosing `List` (an NSTableView underneath), so
/// `SelectedRowBackground` can draw selection the way the theme asks. Placed on a row; idempotent.
struct ListHighlightSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.suppress() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            suppress()
        }
        func suppress() {
            var view = superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            guard let table = view as? NSTableView, table.selectionHighlightStyle != .none else { return }
            table.selectionHighlightStyle = .none
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A selected row: the palette's fill (琥珀, 像素), a fill with a 2 pt accent bar (锌莓), or the accent itself while the
/// list's card has focus and a neutral fill when it does not (石墨, like Finder).
struct SelectedRowBackground: View {
    let selected: Bool
    let focused: Bool
    /// Inside a `List` row background the selection keeps clear of the list's edges; elsewhere it fills the row.
    var inset = true
    @Environment(\.folmiTheme) private var theme
    var body: some View {
        let style = theme.style
        let shape = RoundedRectangle(cornerRadius: style.rowRadius, style: .continuous)
        Group {
            if selected {
                switch style.selection {
                case .tint:
                    shape.fill(.themed(.selectedFill))
                case .bar:
                    Rectangle().fill(.themed(.selectedFill))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.themed(.accent)).frame(width: 2)
                        }
                case .solid:
                    shape.fill(focused ? AnyShapeStyle(ThemeColor(token: .accent)) : AnyShapeStyle(ThemeColor(token: .selectedFill)))
                }
            } else {
                Color.clear
            }
        }
        // Rounded selections sit inside the list's margins; 锌莓's bar runs edge to edge.
        .padding(.horizontal, style.selection == .bar || !inset ? 0 : 6)
        .padding(.vertical, style.selection == .bar || !inset ? 0 : 1)
    }
}

/// 锌莓's diffstat beside a file: +N in the added color, −N in the removed color, monospaced.
struct LineCountText: View {
    let counts: LineCount
    var onAccent = false
    var body: some View {
        HStack(spacing: 4) {
            if counts.added > 0 || counts.removed == 0 {
                Text("+\(counts.added)").foregroundStyle(ThemeColor(token: onAccent ? .onAccent : .added))
            }
            if counts.removed > 0 {
                Text("−\(counts.removed)").foregroundStyle(ThemeColor(token: onAccent ? .onAccent : .removed))
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .accessibilityLabel("增加 \(counts.added) 行，删除 \(counts.removed) 行")
    }
}

extension FolmiModel {
    /// Refreshes `lineCounts` for the current snapshot; called by the change list only while the theme shows them.
    func loadLineCounts() async {
        guard theme.style.instrument, let repository, let snapshot else { return }
        let untracked = snapshot.files.filter(\.isUntracked).map(\.path)
        do {
            let counts = try await repository.lineCounts(untracked: untracked)
            guard snapshot.fingerprint == self.snapshot?.fingerprint else { return }
            if counts != lineCounts { lineCounts = counts }
        } catch {
            AppLog.failure("读取增删行数失败", error)
        }
    }
}

extension ThemeStyle {
    /// The primary button's outline, for washes and overlays that must match it.
    var prominentShape: AnyShape {
        switch prominent {
        case .clay: return AnyShape(Capsule())
        case .sharp: return AnyShape(RoundedRectangle(cornerRadius: min(4, controlRadius), style: .continuous))
        case .flat: return AnyShape(RoundedRectangle(cornerRadius: controlRadius, style: .continuous))
        }
    }
}

/// A 2 pt line that runs from the leading edge to the full width once per new `trigger`, then fades.
struct CommitSweepLine: View {
    let trigger: String?
    @State private var progress = 0.0
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            Rectangle().fill(.themed(.added))
                .frame(width: geometry.size.width * progress, height: 2)
                .opacity(visible ? 1 : 0)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, value in
            guard value != nil, !reduceMotion else { return }
            progress = 0
            visible = true
            withAnimation(Motion.resolved(.easeInOut(duration: 0.55), reduceMotion: reduceMotion)) { progress = 1 }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.75))
                withAnimation(Motion.resolved(.easeOut(duration: 0.3), reduceMotion: reduceMotion)) { visible = false }
            }
        }
    }
}
