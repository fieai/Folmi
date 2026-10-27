import AppKit
import SwiftUI

/// The keyboard cheat sheet: hold ⌘ alone for a moment (or ⌘/) and the shortcuts show over the window; letting go,
/// pressing a key or clicking hides it. On the review page its keys come first.
struct ShortcutGroup: Identifiable {
    let title: String
    let items: [(keys: String, title: String)]
    var id: String { title }

    static func all(reviewing: Bool, ideaKey: String = IdeaHotKey.standard.title) -> [ShortcutGroup] {
        let review = ShortcutGroup(title: "逐个验收", items: [
            ("空格 / ⇧空格", "下一处 / 上一处没看过的"), ("⏎", "这处可以（暂存）"), ("⌫", "这处不要（撤回）"),
            ("j  k", "下一处 / 上一处"), (".  ,", "下一个 / 上一个文件"), ("u", "标记看过 / 没看过"),
            ("s", "暂存或取消暂存"), ("c", "写一条审阅评论"), ("e", "打开编辑"), ("f", "折叠文件")
        ])
        let general = [
            ShortcutGroup(title: "找东西", items: [
                ("⌘K", "万能搜索"), ("⌘P", "快速打开文件"), ("⌘⇧F", "项目全文搜索"), ("⌘⇧T", "待办"), ("⌃⌥H", "调用关系"), ("⌘⇧O", "项目总览")
            ]),
            ShortcutGroup(title: "面板", items: [
                ("⌘1 / ⌘2 / ⌘3", "改动 / 编辑器 / 终端"), ("⌘⇧E", "文件树"), ("⌃⇧G", "Git 改动"),
                ("⌘⇧⏎", "最大化 / 还原面板"), ("⌥⌘W", "收起当前面板"), ("⌃`", "显示 / 隐藏终端"), ("⌃⇧`", "新建终端标签")
            ]),
            ShortcutGroup(title: "Git", items: [
                ("⌥⌘Z", "撤销 Git 操作"), ("⌥⇧⌘Z", "重做 Git 操作"), ("⌘⏎", "提交"), ("⌘R", "重新读取状态")
            ]),
            ShortcutGroup(title: "AI 和终端", items: [
                ("⌘L", "问 AI"), ("⌘⇧L", "说人话（终端选中内容）"), ("⌥⌘L", "编辑器选中的行发到终端"),
                ("⌥⌘⏎", "审阅评论发到终端"), (ideaKey, "随手记（任何 App 里都能按）")
            ]),
            ShortcutGroup(title: "编辑", items: [
                ("⌘S / ⌘⇧S", "保存 / 全部保存"), ("⌥⇧M", "Markdown 阅读 / 编辑"), ("⌘⇧Y", "这份文档的演变史")
            ])
        ]
        return reviewing ? [review] + general : general + [review]
    }
}

/// Watches ⌘ held on its own. Lives as long as the app; only touches `model.showShortcuts`.
@MainActor
final class CommandHoldMonitor {
    static let shared = CommandHoldMonitor()
    static let delay: TimeInterval = 0.8
    private weak var model: FolmiModel?
    private var monitor: Any?
    private var pending: DispatchWorkItem?

    func start(model: FolmiModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .flagsChanged, flags == .command {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let model = self?.model, NSApp.isActive, NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return }
                model.showShortcuts = .held
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
            return
        }
        // Anything else — another modifier, letting go, a key (⌘K…), a click — cancels and hides a held sheet.
        pending?.cancel(); pending = nil
        let closesPinned = (event.type == .keyDown && event.keyCode == 53) || event.type == .leftMouseDown || event.type == .rightMouseDown
        if closesPinned, model?.showShortcuts == .pinned { model?.showShortcuts = .hidden; return }
        if model?.showShortcuts == .held { model?.showShortcuts = .hidden }
    }
}

enum ShortcutSheetState { case hidden, held, pinned }

struct ShortcutOverlay: View {
    let model: FolmiModel
    @Environment(\.folmiTheme) private var theme

    var body: some View {
        // Reading the state here keeps the window itself from re-rendering when the sheet opens or closes.
        ZStack { content }.motion(.easeOut(duration: 0.12), value: model.showShortcuts)
    }

    @ViewBuilder private var content: some View {
        if model.showShortcuts != .hidden {
            let groups = ShortcutGroup.all(reviewing: model.content == .allChanges, ideaKey: model.ideaHotKey.title)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("快捷键").themedFont(.headline, points: 12)
                    Spacer()
                    Text(model.showShortcuts == .held ? "松开 ⌘ 收起" : "⌘/ 或 Esc 收起")
                        .themedFont(.caption, points: 10).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .topLeading)], alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.title).themedFont(.caption.weight(.semibold), points: 10).foregroundStyle(.secondary)
                            ForEach(group.items, id: \.keys) { item in
                                HStack(spacing: 8) {
                                    Text(item.keys)
                                        .themedFont(.system(size: 11, weight: .medium, design: .monospaced), points: 12)
                                        .frame(minWidth: 96, alignment: .leading)
                                    Text(item.title).themedFont(.callout, points: 12)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: theme.style.radius(.card) + 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.style.radius(.card) + 4, style: .continuous).strokeBorder(ThemeColor(token: .border)))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
            .padding(40)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("快捷键一览")
        }
    }
}
