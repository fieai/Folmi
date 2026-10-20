import SwiftUI

/// 试一试: four steps in a demo project that show the review loop by doing it. Each ticks itself off when done
/// anywhere in the app; the card goes away once all are done or when closed. Kept in tour.json next to the settings.
struct TourState: Codable, Equatable {
    enum Step: String, Codable, CaseIterable {
        case review, accept, undo, shortcuts
        var title: String {
            switch self {
            case .review: return "打开「逐个验收」"
            case .accept: return "按 ⏎ 收下一处改动"
            case .undo: return "按 ⌥⌘Z 撤销刚才那一步"
            case .shortcuts: return "按住 ⌘ 不放，看全部快捷键"
            }
        }
    }
    var done: Set<Step> = []
    var dismissed = false
    var finished: Bool { done.count == Step.allCases.count }

    private static var url: URL { AppFiles.directory.appendingPathComponent("tour.json") }
    static func load() -> TourState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(TourState.self, from: data) else { return TourState() }
        return state
    }
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let url = Self.url
        DispatchQueue.global(qos: .utility).async { AppLog.attempt("试一试进度写入失败") { try data.write(to: url, options: .atomic) } }
    }
}

extension FolmiModel {
    func completeTour(_ step: TourState.Step) {
        guard !tour.dismissed, !tour.done.contains(step) else { return }
        tour.done.insert(step)
        tour.save()
        if tour.finished {
            // Let the last tick show, then fold the card away for good.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.dismissTour() }
        }
    }
    func dismissTour() {
        guard !tour.dismissed else { return }
        withMotion(.easeOut(duration: 0.2)) { tour.dismissed = true }
        tour.save()
    }
    var showsTour: Bool { isDemo && !tour.dismissed && snapshot != nil }
}

struct TourCard: View {
    let model: FolmiModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if model.showsTour {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.tour.finished ? "都试过了" : "试一试").themedFont(.callout.weight(.semibold), points: 12)
                    Spacer()
                    Button { model.dismissTour() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("不再显示").accessibilityLabel("关闭试一试")
                }
                ForEach(TourState.Step.allCases, id: \.self) { step in
                    let done = model.tour.done.contains(step)
                    HStack(spacing: 8) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(done ? ThemeColor(token: .added) : ThemeColor(token: .secondaryText))
                            .contentTransition(.symbolEffect(.replace))
                        Text(step.title).themedFont(.caption, points: 10)
                            .foregroundStyle(done ? .secondary : .primary)
                            .strikethrough(done, color: .secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(step.title + (done ? "，已完成" : ""))
                }
                if model.tour.finished {
                    Text("平时就这样：Claude 改完，空格往下看，⏎ 收下，⌫ 不要，⌥⌘Z 反悔。").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 250, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: model.theme.style.radius(.card) + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: model.theme.style.radius(.card) + 2, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .padding(18)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.tour)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
