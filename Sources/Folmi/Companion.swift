import SwiftUI

/// 琥珀's companion: what the Folmi mascot shows, decided only by real work (docs/brand/folmi-motion.md). It never
/// carries meaning alone; the status text beside it always says the same thing.
enum CompanionState: Hashable {
    case idle, working, thinking, success, attention, error, sleep

    /// Higher wins when several hold at once; errors and anything waiting on the user stay until handled.
    var priority: Int {
        switch self {
        case .error: return 80
        case .attention: return 60
        case .success: return 40
        case .working, .thinking: return 20
        case .sleep: return 5
        case .idle: return 0
        }
    }

    /// The still face for this state (status bar, Reduce Motion).
    var pose: FolmiGreeting.Pose {
        var pose = FolmiGreeting.Pose.rest
        switch self {
        case .idle: break
        case .working: pose.eyes = .down
        case .thinking: pose.eyes = .up
        case .success: pose.eyes = .happy
        case .attention: pose.ear = -16
        case .error: pose.ear = 18; pose.eyes = .narrow
        case .sleep: pose.eyes = .closed
        }
        return pose
    }

    /// The face at `t` seconds into the state. Loops stay small (a blink, a 2° sweep); one-shots settle and hold.
    func pose(at t: Double) -> FolmiGreeting.Pose {
        var pose = self.pose
        guard t.isFinite else { return pose }
        func blink(every period: Double) -> Double {
            let phase = t.truncatingRemainder(dividingBy: period)
            return phase > period - 0.18 ? 0.12 : 1
        }
        switch self {
        case .idle:
            pose.blink = blink(every: 7.2)
        case .working:
            pose.tail = 2 * sin(t / 3.2 * 2 * .pi)
            pose.blink = blink(every: 9)
        case .thinking:
            pose.ear = -6 * max(0, sin(t / 4.8 * 2 * .pi))
            pose.blink = blink(every: 9)
        case .success:
            // One nod, then exactly still.
            let nod = t < 0.9 ? sin(t / 0.9 * .pi) : 0
            pose.lift = 10 * nod
            pose.accent = nod
        case .attention:
            pose.ear = -16 * min(1, t / 0.3)
        case .error:
            pose.ear = 18 * min(1, t / 0.45)
        case .sleep:
            let breath = 0.008 * sin(t / 5.2 * 2 * .pi)
            pose.scaleX = 1 + breath; pose.scaleY = 1 - breath
        }
        return pose
    }

    /// Whether the state keeps moving after it settles; one-shot states stop drawing once they hold.
    var loops: Bool { [.idle, .working, .thinking, .sleep].contains(self) }
}

struct CompanionStatus: Equatable {
    var state: CompanionState
    /// What the status bar says; nil keeps the bar's own wording.
    var text: String?
}

extension FolmiModel {
    /// The companion's lasting state from the model. A fresh commit's short `success` is layered on by the view.
    var companionStatus: CompanionStatus {
        if let error = errorMessage, !error.isEmpty {
            let line = error.split(separator: "\n").first.map(String.init) ?? error
            return CompanionStatus(state: .error, text: line)
        }
        if case let .finished(files, _, _) = capsule {
            return CompanionStatus(state: .attention, text: "改完了 · \(files) 个文件等你看")
        }
        if case let .working(files, _) = capsule {
            return CompanionStatus(state: .working, text: files > 0 ? "正在改 \(files) 个文件…" : "AI 正在干活…")
        }
        if agentSession?.isBusy == true { return CompanionStatus(state: .working, text: "AI 正在回答…") }
        if commitSuggestion == .generating { return CompanionStatus(state: .thinking, text: "正在写提交说明…") }
        if busy { return CompanionStatus(state: .working, text: "正在执行…") }
        if !hasSnapshot { return CompanionStatus(state: .sleep, text: nil) }
        return CompanionStatus(state: .idle, text: nil)
    }
}

/// The mascot drawn at `size`. Static (status bar, Reduce Motion, small sizes) or animated from the moment the
/// state began; loops stop drawing while the window is inactive.
struct CompanionMark: View {
    let state: CompanionState
    var size: CGFloat = 48
    var animated = true
    @Environment(\.companionMotion) private var companionMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var since = Date()
    @State private var settled = false

    /// Below 32 pt the parts are too small to move without shimmering (folmi-motion.md).
    private var moving: Bool { animated && companionMotion && size >= 32 && !reduceMotion && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !moving || settled)) { timeline in
            Canvas { context, canvasSize in
                let t = moving ? timeline.date.timeIntervalSince(since) : .infinity
                FolmiGreeting.draw(context, size: canvasSize, pose: moving ? state.pose(at: t) : state.pose, gaze: .zero)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: state) { _, _ in since = Date(); settled = false }
        .task(id: state) {
            // One-shot states hold their last face; stop the clock once they have played.
            guard !state.loops else { return }
            do { try await Task.sleep(for: .seconds(1.3)) } catch { return }
            settled = true
        }
        .accessibilityHidden(true)
    }
}

/// The status bar's leading item under 琥珀: the still mascot and what it means. A new commit shows `success` for a
/// moment, then the lasting state returns.
struct CompanionStatusItem: View {
    let model: FolmiModel
    @State private var celebrating: CommitToast?

    var body: some View {
        let lasting = model.companionStatus
        let showSuccess = celebrating != nil && lasting.state.priority < CompanionState.success.priority
        let state = showSuccess ? .success : lasting.state
        HStack(spacing: 5) {
            CompanionMark(state: state, size: 16, animated: false)
            Text(showSuccess ? "已提交 \(celebrating?.id.prefix(7) ?? "")" : lasting.text ?? (model.hasSnapshot ? "就绪" : "选择仓库开始"))
                .foregroundStyle(ThemeColor(token: state == .error ? .removed : state == .attention ? .modified : .secondaryText))
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .onChange(of: model.lastCommit) { _, toast in
            guard let toast else { return }
            celebrating = toast
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                if celebrating == toast { celebrating = nil }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CompanionMotionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// The 陪伴动画 preference; Reduce Motion stops the mascot regardless.
    var companionMotion: Bool {
        get { self[CompanionMotionKey.self] }
        set { self[CompanionMotionKey.self] = newValue }
    }
}
