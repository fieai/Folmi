import SwiftUI
import FolmiCore

struct FolmiView: View {
    @Bindable var model: FolmiModel

    var body: some View {
        let _ = PerfLog.body("FolmiView")
        Group {
            if model.gitStartupState.blocksGit {
                StartupEnvironmentView(model: model)
            } else {
                FolmiMain(model: model)
            }
        }
        .frame(minWidth: 1020, minHeight: 650)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FolmiStatusBar(model: model)
        }
        // Inside the toolbar modifier, so toolbar buttons keep the system look.
        .buttonStyle(ThemedDefaultButtonStyle())
        .navigationTitle(model.repositoryTitle)
        .tint(Color.theme(model.theme, \.accent))
        .environment(\.companionMotion, model.companionMotion)
        .preferredColorScheme(model.colorScheme)
        .background { WindowBackdrop(theme: model.theme, glass: model.glassSurfaces) }
        .overlay { ShortcutOverlay(model: model) }
        .background(WindowChrome(color: model.theme.palette.canvas, glass: model.glassSurfaces))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // Opening and refreshing are occasional; one menu holds them (and the 文件 menu has their shortcuts).
                Menu {
                    Button("打开仓库…（⌘O）", action: model.openRepository).disabled(model.busy)
                    Button("创建演示仓库", action: model.loadDemo).disabled(model.busy)
                    Divider()
                    Button("重新读取状态（⌘R）", action: model.refresh).disabled(!model.hasSnapshot || model.busy)
                } label: { Label("仓库", systemImage: "folder") }
                .help("打开仓库、新建演示仓库、重新读取状态")
            }
            ToolbarItem(placement: .principal) { BranchMenu(model: model) }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: model.openProjectSearch) { Label("全文搜索", systemImage: "magnifyingglass") }
                    .help("搜索项目文本（⌘⇧F）；快速打开文件用 ⌘P").disabled(!model.hasSnapshot || model.busy)
                Button(action: model.toggleTerminal) { Label("终端", systemImage: "terminal") }
                    .keyboardShortcut("`", modifiers: .control)
                    .disabled(!model.hasSnapshot).help("显示或隐藏内嵌终端（Control+`）")
                Button {
                    model.showActivity = true
                } label: {
                    Label("操作记录", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .sheet(isPresented: $model.showDelivery) {
            DeliverySheet(model: model).sheetEntrance()
        }
        .sheet(isPresented: $model.showPull) {
            PullSheet(model: model).sheetEntrance()
        }
        .sheet(isPresented: $model.showStashes) {
            StashSheet(model: model).sheetEntrance()
        }
        .sheet(isPresented: $model.showActivity) {
            ActivitySheet(model: model).sheetEntrance()
        }
        .sheet(isPresented: $model.showAISettings) { AISettingsSheet(model: model).sheetEntrance() }
        .sheet(isPresented: $model.showSettings) { FolmiSettingsSheet(model: model).sheetEntrance() }
        .sheet(isPresented: $model.showPalette) {
            CommandPaletteSheet(items: model.paletteItemsCache, usage: model.paletteUsage, onPick: model.pickPaletteItem).sheetEntrance()
        }
        .sheet(isPresented: $model.showHooksSetup) { HooksSetupSheet(model: model).sheetEntrance() }
        .sheet(isPresented: $model.showMemory) { MemorySheet(model: model).sheetEntrance() }
        .sheet(isPresented: $model.showTasks) { TasksSheet(model: model).sheetEntrance() }
        .sheet(isPresented: $model.showReplay) { ReplaySheet(model: model).sheetEntrance() }
        .sheet(isPresented: $model.showOverview) { ProjectOverviewSheet(model: model).sheetEntrance() }
        .sheet(isPresented: $model.showDocHistory) { DocHistorySheet(model: model).sheetEntrance() }
        .sheet(isPresented: $model.showQuickOpen) {
            QuickOpenSheet(paths: model.quickOpenPaths, onOpen: model.openQuickMatch).sheetEntrance()
        }
        .sheet(isPresented: $model.showProjectSearch, onDismiss: model.cancelProjectSearch) {
            VStack(spacing: 0) {
                HStack {
                    Text("项目全文搜索 · \(model.repositoryTitle)").themedFont(.headline, points: 13)
                    Spacer()
                    Button("关闭") { model.showProjectSearch = false }.keyboardShortcut(.cancelAction)
                }.padding(14)
                Divider()
                ProjectSearchPanel(result: model.projectSearchResult, searching: model.projectSearching,
                                   query: $model.projectSearchQuery, caseSensitive: $model.searchCaseSensitive,
                                   onSearch: model.performProjectSearch, onOpen: model.openSearchHit)
            }.frame(width: 840, height: 600).sheetEntrance()
        }
        .background(SheetOutsideClick(dismiss: model.dismissSheets))
        .alert("操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            if model.missingProjectPath != nil {
                Button("重新定位…") { model.errorMessage = nil; model.relocateMissingProject() }
                Button("从项目列表移除", role: .destructive) { model.removeMissingProject() }
            } else if model.notRepositoryPath != nil {
                Button("选择其他文件夹…") { model.chooseAnotherRepository() }
            }
            Button("知道了", role: .cancel) { model.errorMessage = nil; model.missingProjectPath = nil; model.notRepositoryPath = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // Text without its own font (labels, buttons, menus) in the pixel font under 像素; reads the theme set below.
        .themedFont(.body, points: 13)
        // Last, so the sheets above (push, pull, settings…) get the theme too, not just the window. The accent tint
        // stays on the window: in a sheet it would turn every plain button into accent-colored text.
        .environment(\.folmiTheme, model.theme)
        .environment(\.folmiGlass, model.glassSurfaces)
        .environment(\.foldWhitespaceHunks, model.foldWhitespace)
        // Reading repositoryURL (observed) re-reads the repository when the project changes.
        .environment(\.gitRepository, model.repositoryURL == nil ? nil : model.repository)
        // A design swaps a custom font for the system one in that design, so the pixel font goes without it.
        .fontDesign(model.theme.style.pixelFont && PixelFont.isAvailable ? nil : model.theme.style.fontDesign)
    }
}

/// The branch switcher; it is the only toolbar item that reads the Git status, so a refresh re-renders just this.
private struct BranchMenu: View {
    let model: FolmiModel
    var body: some View {
        let _ = PerfLog.body("BranchMenu")
        if let snapshot = model.snapshot {
            let unpushed = snapshot.unpushed ?? 0
            Menu {
                if unpushed > 0 {
                    Button("推送 \(unpushed) 个提交…", action: model.prepareDelivery)
                }
                if snapshot.upstream != nil {
                    let behind = snapshot.behind ?? 0
                    Button(behind > 0 ? "拉取 \(behind) 个提交…" : "检查远端更新…", action: model.preparePull)
                }
                if unpushed > 0 || snapshot.upstream != nil { Divider() }
                ForEach(snapshot.branches, id: \.self) { branch in
                    Button {
                        model.checkout(branch)
                    } label: {
                        if branch == snapshot.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
            } label: {
                // A toolbar menu draws only the label's first text, so the counts are part of it.
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                    (Text(snapshot.branch.isEmpty ? "尚无分支" : snapshot.branch)
                     + Text(unpushed > 0 ? "  ↑\(unpushed)" : "").foregroundColor(Color.theme(model.theme, \.modified))
                     + Text((snapshot.behind ?? 0) > 0 ? "  ↓\(snapshot.behind ?? 0)" : "").foregroundColor(.secondary))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.busy || (snapshot.branches.isEmpty && unpushed == 0 && snapshot.upstream == nil))
            .help(unpushed > 0 ? "\(unpushed) 个提交还没推送；点开可推送、拉取或切换分支"
                  : ((snapshot.behind ?? 0) > 0 ? "远端有 \(snapshot.behind ?? 0) 个新提交；点开可拉取" : "切换本地分支；未提交改动由 Git 检查"))
        }
    }
}

// Each part of the window is its own view and reads only the model values it shows, so a change (an editor tab, the
// tree selection, the capsule, a commit-message keystroke) re-renders that part instead of the whole window, its
// toolbar and its accessibility tree. Children get only references (model, tracker, sizes) and bindings, never
// closures, so SwiftUI can skip them when a parent re-renders.

/// The window below the toolbar: project rail, the three cards, and the notices floating over them.
private struct FolmiMain: View {
    let model: FolmiModel
    @StateObject private var paneTracker = PaneFocusTracker()
    /// Not observed here on purpose (plain @State): a drag re-renders only the size boxes, never this body.
    @State private var paneSizes = PaneSizes()
    @State private var treeQuery = ""
    @State private var projectNamesExpanded = true
    @StateObject private var treeExpansion = ProjectTreeExpansion()

    var body: some View {
        let _ = PerfLog.body("FolmiMain")
        if model.hasSnapshot {
            HStack(spacing: 0) {
                ProjectRail(model: model, expanded: $projectNamesExpanded)
                PaneHost(model: model, tracker: paneTracker, sizes: paneSizes, treeQuery: $treeQuery, treeExpansion: treeExpansion,
                         projectRailWidth: projectNamesExpanded ? 168 : 48)
            }
            .overlay(alignment: .top) { TopNotices(model: model) }
            .overlay(alignment: .bottomTrailing) { FloatingAssist(model: model) }
            .overlay(alignment: .bottomTrailing) { TourCard(model: model) }
            .task(id: model.repositoryURL) {
                // The "finished" capsule fades out on its own after a while.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    model.updateCapsule()
                }
            }
            .onAppear {
                paneSizes.sync(from: model.paneLayout)
                // The tracker outlives this closure; it must not keep the model alive.
                weak let target = model
                paneTracker.onClick = { target?.notePaneClicked($0) }
                paneTracker.start()
            }
            .onDisappear { paneTracker.stop() }
            .onChange(of: model.paneLayout) { _, layout in paneSizes.sync(from: layout) }
            .onChange(of: model.paneFocusRequest) { _, request in
                guard let request else { return }
                // Let SwiftUI insert a reopened card before looking for its text view or terminal.
                DispatchQueue.main.async {
                    paneTracker.makeFirstResponder(request.pane,
                                                   preferCommitEditor: request.prefersCommitEditor)
                }
            }
        } else { WelcomeView(model: model) }
    }
}

private struct TopNotices: View {
    let model: FolmiModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let _ = PerfLog.body("TopNotices")
        VStack(spacing: 8) {
            ActivityCapsuleView(model: model)
            LargeRepositoryOffer(model: model)
        }
        .padding(.top, 4)
        .animation(reduceMotion ? nil : Motion.reveal, value: model.capsule)
    }
}

private struct FloatingAssist: View {
    let model: FolmiModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let _ = PerfLog.body("FloatingAssist")
        // On the review page an explanation docks beside the diff instead (AllChangesView).
        if !model.assistBesideReview {
            AIAssistCard(model: model).padding(18)
                .animation(reduceMotion ? nil : Motion.state, value: model.aiAssist?.mode)
        }
    }
}

private struct ProjectRail: View {
    let model: FolmiModel
    @Binding var expanded: Bool
    @State private var removing: ProjectPreferences?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 8) {
            Button { withAnimation(reduceMotion ? nil : Motion.layout) { expanded.toggle() } } label: {
                RailRowLabel(symbol: "sidebar.left", title: "项目", expanded: expanded)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel(expanded ? "收起项目名称" : "展开项目名称").help(expanded ? "收起项目名称" : "展开项目名称")
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(RailEntry.entries(projects: model.projects, current: model.repositoryURL?.path, worktrees: model.worktrees)) { entry in
                        switch entry {
                        case .project(let project):
                            projectRow(project, letter: String(project.name.prefix(1)).uppercased(), title: project.name, worktree: false)
                        case .worktreeProject(let project, let branch):
                            projectRow(project, letter: nil, title: branch ?? project.name, worktree: true)
                        case .unopened(let worktree):
                            Button { model.open(URL(fileURLWithPath: worktree.path)) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).frame(width: 28, height: 26)
                                    Text(worktree.isMain ? "\(worktree.title)（主目录）" : worktree.title)
                                        .themedFont(.system(size: 11.5), points: 11.5).lineLimit(1).truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading).opacity(expanded ? 1 : 0)
                                }
                                .modifier(RailRowInsets())
                                .foregroundStyle(.secondary).opacity(0.75)
                            }
                            .buttonStyle(.pressableRow).disabled(model.busy)
                            .accessibilityLabel("打开工作树 \(worktree.title)")
                            .help("同一仓库的另一个工作树，还没打开：\(worktree.title)\n\(worktree.path)\n点一下打开")
                        }
                    }
                }
            }.frame(maxHeight: .infinity)
            Button(action: model.openRepository) {
                RailRowLabel(symbol: "plus", title: "添加项目…", expanded: expanded)
            }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.busy)
                .accessibilityLabel("添加项目").help("添加项目（⌘O）")
            ForEach(model.paneLayout.closedPanes, id: \.self) { pane in
                Button { model.focusPane(pane) } label: {
                    RailRowLabel(symbol: pane.systemImage, title: "恢复\(pane.title)", expanded: expanded)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("恢复\(pane.title)（⌘\(String(pane.shortcut.character))）")
            }
            Menu {
                ThemeMenuItems(model: model)
                Divider()
                MarkdownReadingMenu(model: model)
                Divider()
                Button("增大字号（当前 \(Int(model.editorFontSize))）") { model.changeFontSize(1) }
                Button("减小字号") { model.changeFontSize(-1) }
            } label: {
                RailRowLabel(symbol: model.appearance.symbol, title: "外观", expanded: expanded)
            }
            // A plain button menu draws the label as laid out, so its icon stays in the same column as the others.
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .foregroundStyle(.secondary).accessibilityLabel("外观与阅读排版")
            .help("明暗：\(model.appearance.title) · 主题：\(model.theme.title)")
            Menu {
                Button("设置…（⌘,）") { model.showSettings = true }
                Button("AI 设置…") { model.showAISettings = true }
                Button("接入 agent…") { model.showHooksSetup = true }.disabled(!model.hasSnapshot)
                Button("记住了什么…") { model.showMemory = true }.disabled(!model.hasSnapshot)
            } label: {
                RailRowLabel(symbol: "gearshape", title: "设置", expanded: expanded)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .foregroundStyle(.secondary).accessibilityLabel("设置")
            .help("设置、AI 设置、接入 agent、记住了什么")
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .frame(width: ProjectRail.openContentWidth + 16)
        .frame(width: expanded ? ProjectRail.openContentWidth + 16 : 48, alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .folmiSurface(.rail)
        .confirmationDialog("从项目列表移除「\(removing?.name ?? "")」？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { project in
            Button("移除", role: .destructive) { model.removeProject(project.rootPath) }
            Button("取消", role: .cancel) {}
        } message: { project in
            Text(project.rootPath == model.repositoryURL?.path
                 ? "会先切换到另一个项目。只从 Folmi 的列表移除，不会删除磁盘上的文件；这个项目的审阅评论会一起清掉。"
                 : "只从 Folmi 的列表移除，不会删除磁盘上的文件；这个项目的审阅评论会一起清掉。")
        }
    }

    /// One project in the rail; a worktree of the project above it is drawn with a branch mark and its branch name.
    private func projectRow(_ project: ProjectPreferences, letter: String?, title: String, worktree: Bool) -> some View {
        let selected = model.repositoryURL?.path == project.rootPath
        return Button { model.switchProject(project.rootPath) } label: {
            HStack(spacing: 8) {
                Group {
                    if let letter {
                        Text(letter).themedFont(.system(size: 13, weight: .semibold), points: 13)
                    } else {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .medium))
                    }
                }
                .frame(width: 28, height: worktree ? 26 : 30)
                // Always laid out at the open width and only faded, so nothing re-wraps while the rail
                // slides open or shut.
                Text(title).themedFont(.system(size: worktree ? 11.5 : 12, weight: selected ? .semibold : .regular), points: worktree ? 11.5 : 12)
                    .lineLimit(worktree ? 1 : 2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(expanded ? 1 : 0)
                if project.isDemo { Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(.secondary).opacity(expanded ? 1 : 0) }
            }
            .modifier(RailRowInsets())
            .padding(.vertical, worktree ? 2 : 4)
            .foregroundStyle(ThemeColor(token: selected ? .accent : .foreground))
            .background(alignment: .leading) {
                // The pill hugs the letter while closed and opens with the rail.
                RoundedRectangle(cornerRadius: model.theme.style.radius(.control))
                    .fill(ThemeColor(token: selected ? .selectedFill : .card,
                                     opacity: (!selected && model.theme == .terrazzo && colorScheme == .dark) || (worktree && !selected) ? 0 : 1))
                    .frame(width: expanded ? ProjectRail.openContentWidth : 32)
            }
        }
        .buttonStyle(.pressableRow).disabled(model.busy)
        .accessibilityLabel(worktree ? "工作树 \(title)" : project.name)
        .help(worktree ? "\(project.name) 的工作树：\(title)\n\(project.rootPath)" : "\(project.name)\n\(project.rootPath)")
        .contextMenu {
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.rootPath)]) }
            Divider()
            Button("从项目列表移除…") { removing = project }
                .disabled(model.busy || !model.canRemoveProject(project.rootPath))
        }
    }

    /// The rail's rows are always this wide; closing the rail clips them to the icon column.
    static let openContentWidth: CGFloat = 152
}

/// Every rail row keeps its icon in one 28-point column, centered in the collapsed rail, so nothing shifts sideways
/// when names are shown or hidden.
private struct RailRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.leading, 2).padding(.trailing, 6)
            .frame(width: ProjectRail.openContentWidth, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct RailRowLabel: View {
    let symbol: String
    let title: String
    let expanded: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 28, height: 28)
            Text(title).themedFont(.callout, points: 12).lineLimit(1).opacity(expanded ? 1 : 0)
            Spacer(minLength: 0)
        }
        .modifier(RailRowInsets())
    }
}

/// Lays out the cards and their resize handles; it reads only which cards are shown.
private struct PaneHost: View {
    let model: FolmiModel
    let tracker: PaneFocusTracker
    let sizes: PaneSizes
    @Binding var treeQuery: String
    let treeExpansion: ProjectTreeExpansion
    let projectRailWidth: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = PerfLog.body("PaneHost")
        let layout = model.paneLayout
        let sideShown = layout.isShown(.changes)
        let editorShown = layout.isShown(.editor)
        let terminalShown = layout.isShown(.terminal) && model.terminalSession != nil
        let rightShown = editorShown || terminalShown
        GeometryReader { available in
        let sidebarMaximum = max(PaneLayoutState.sidebarRange.lowerBound,
                                 min(PaneLayoutState.sidebarRange.upperBound, Double(available.size.width) - 24 - 420))
        HStack(spacing: 0) {
            if sideShown {
                Group {
                    if rightShown {
                        PaneSizeBox(sizes: sizes, dimension: .sidebarWidth, maximumWidth: sidebarMaximum).overlay { sideCard }
                    } else { sideCard.frame(maxWidth: .infinity) }
                }
                .transition(.paneSlide(edge: .leading))
                if rightShown {
                    PaneResizeHandle(axis: .horizontal, thickness: model.theme.style.paneGap, elastic: true, value: { sizes.sidebarWidth },
                                     limit: { size in PaneLayoutState.sidebarRange.lowerBound...max(PaneLayoutState.sidebarRange.lowerBound,
                                         min(PaneLayoutState.sidebarRange.upperBound, Double(size.width) - projectRailWidth - 24 - 420)) },
                                     onBegin: sizes.begin, onChange: { sizes.sidebarWidth = $0 },
                                     onEnd: commitPaneSizes, onReset: { resetPaneSize(.sidebarWidth) },
                                     help: "拖动调整宽度，双击恢复默认")
                }
            }
            if rightShown {
                VStack(spacing: 0) {
                    if editorShown {
                        EditorCard(model: model, tracker: tracker).frame(minHeight: 170)
                            .transition(.paneSlide(edge: .top))
                    }
                    if editorShown && terminalShown {
                        PaneResizeHandle(axis: .vertical, inverted: true, thickness: model.theme.style.paneGap, elastic: true, value: { sizes.terminalHeight },
                                         limit: { size in PaneLayoutState.terminalRange.lowerBound...max(PaneLayoutState.terminalRange.lowerBound,
                                             min(PaneLayoutState.terminalRange.upperBound, Double(size.height) - 44 - 16 - 8 - 200)) },
                                         onBegin: sizes.begin, onChange: { sizes.terminalHeight = $0 },
                                         onEnd: commitPaneSizes, onReset: { resetPaneSize(.terminalHeight) },
                                         help: "拖动调整终端高度，双击恢复默认")
                    }
                    if terminalShown {
                        Group {
                            if editorShown {
                                PaneSizeBox(sizes: sizes, dimension: .terminalHeight).overlay { TerminalCard(model: model, tracker: tracker) }
                            } else { TerminalCard(model: model, tracker: tracker) }
                        }
                        .transition(.paneSlide(edge: .bottom))
                    }
                }
                .transition(.paneSlide(edge: .trailing))
            }
            if !sideShown && !rightShown {
                WelcomeView(model: model, panesClosed: true).transition(.opacity)
            }
        }
        .padding(.vertical, model.theme.style.paneGap).padding(.horizontal, model.theme.style.paneGap)
        // Which cards are on screen; a change animates cards in and out.
        .animation(reduceMotion ? nil : Motion.layout, value: [sideShown, editorShown, terminalShown])
        }
    }

    private var sideCard: SideCard {
        SideCard(model: model, tracker: tracker, treeQuery: $treeQuery, treeExpansion: treeExpansion)
    }
    private func commitPaneSizes() {
        sizes.end()
        var layout = model.paneLayout
        layout.sidebarWidth = sizes.sidebarWidth
        layout.terminalHeight = sizes.terminalHeight
        if layout != model.paneLayout { model.paneLayout = layout }
    }
    private func resetPaneSize(_ dimension: PaneSizeBox.Dimension) {
        let defaults = PaneLayoutState()
        withAnimation(reduceMotion ? nil : Motion.layout) {
            switch dimension {
            case .sidebarWidth: sizes.sidebarWidth = defaults.sidebarWidth
            case .terminalHeight: sizes.terminalHeight = defaults.terminalHeight
            }
        }
        commitPaneSizes()
    }
}

/// A card's frame; it reads only whether this card is focused or maximized.
@MainActor
func folmiCard<Tabs: View, Accessory: View, Content: View>(
    _ pane: FolmiPane, model: FolmiModel, tracker: PaneFocusTracker,
    @ViewBuilder tabs: () -> Tabs, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
) -> some View {
    PaneCard(pane: pane, focused: model.paneLayout.focused == pane, maximized: model.paneLayout.maximized == pane,
             tracker: tracker, onMaximize: { model.toggleMaximize(pane) }, onClose: { model.closePane(pane) },
             tabs: tabs, accessory: accessory, content: content)
}

/// The launch page. With no project open it offers opening one; inside a project whose cards are all closed
/// (`panesClosed`) it is the same page under the project's name, with the cards as its actions.
private struct WelcomeView: View {
    let model: FolmiModel
    var panesClosed = false
    @State private var branches: [String: String] = [:]

    /// Projects to offer: all of them, or the others while one is open.
    private var recentProjects: [ProjectPreferences] {
        panesClosed ? model.projects.filter { $0.rootPath != model.repositoryURL?.path } : model.projects
    }

    var body: some View {
        let _ = PerfLog.body("WelcomeView")
        VStack(spacing: 0) {
            WelcomeMark()
            Text(panesClosed ? model.repositoryTitle : "Folmi").themedFont(.title.weight(.semibold), points: 22)
                .padding(.top, 6)
            Text(panesClosed ? "面板都已收起，选一个打开。" : "看清 AI 改了什么，再决定留下哪些。")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            HStack(spacing: 12) {
                if panesClosed {
                    ForEach(FolmiPane.allCases, id: \.self) { pane in
                        let title = "\(pane.title)（⌘\(String(pane.shortcut.character))）"
                        if pane == .changes {
                            Button(title) { model.focusPane(pane) }.buttonStyle(.folmiProminent)
                        } else {
                            Button(title) { model.focusPane(pane) }
                        }
                    }
                } else {
                    Button("打开本地仓库", action: model.openRepository)
                        .buttonStyle(.folmiProminent)
                    Button("试用演示仓库", action: model.loadDemo)
                        .help("演示仓库独立创建，可用来试验暂存和提交")
                }
            }
            .controlSize(.large)
            .disabled(model.busy)
            .padding(.top, 18)
            if !recentProjects.isEmpty {
                recents.padding(.top, 24)
            }
            ProgressView().controlSize(.small)
                .opacity(model.busy ? 1 : 0)
                .padding(.top, 14)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.theme(model.theme, \.canvas))
        .task(id: model.projects.map(\.rootPath)) {
            let paths = model.projects.map(\.rootPath)
            branches = await Task.detached { Dictionary(uniqueKeysWithValues: paths.compactMap { path in WelcomeRecents.branch(at: path).map { (path, $0) } }) }.value
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(panesClosed ? "其他项目" : "最近").themedFont(.caption, points: 10)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(recentProjects.prefix(WelcomeRecents.limit).enumerated()), id: \.element.id) { index, project in
                    if index > 0 { Divider() }
                    Button { model.switchProject(project.rootPath) } label: {
                        HStack(spacing: 10) {
                            Text(project.name).fontWeight(.medium).lineLimit(1)
                            if project.isDemo {
                                Text("演示").themedFont(.caption2, points: 9).foregroundStyle(.secondary)
                            } else {
                                Text(WelcomeRecents.abbreviated(project.rootPath))
                                    .themedFont(.caption, points: 10).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            if let branch = branches[project.rootPath] {
                                Text(branch).themedFont(.caption.monospaced(), points: 10)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressableRow)
                    .help(project.rootPath)
                }
            }
            .modifier(FolmiCardShape(focused: false))
        }
        .frame(maxWidth: 420)
        .disabled(model.busy)
    }
}

/// The launch page's recent-project rows: a short path and the checked-out branch, read from HEAD without git.
enum WelcomeRecents {
    static let limit = 8

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The branch name, or a short hash when HEAD is detached; nil when the folder is not a repository.
    static func branch(at root: String) -> String? {
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")
        var gitDir = dotGit
        // A worktree or submodule keeps a `.git` file that points at its real git directory.
        if let link = try? String(contentsOf: dotGit, encoding: .utf8), link.hasPrefix("gitdir:") {
            let target = link.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : URL(fileURLWithPath: root).appendingPathComponent(target)
        }
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        if head.hasPrefix("ref: ") { return String(head.dropFirst("ref: ".count)) }
        return String(head.prefix(7))
    }
}

private struct FolmiStatusBar: View {
    let model: FolmiModel
    var body: some View {
        let _ = PerfLog.body("FolmiStatusBar")
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if model.theme.style.companion {
                    CompanionStatusItem(model: model)
                } else if model.busy {
                    ProgressView().controlSize(.mini)
                    Text("正在执行…")
                } else {
                    if model.theme.style.solidMarks {
                        StatusSquare(token: model.hasSnapshot ? .added : .tertiaryText)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Text(!model.hasSnapshot ? "选择仓库开始" : "就绪")
                }
                // Saving settings is silent when it works; only a problem is worth the space.
                if !["", "已保存个人配置", "配置已载入"].contains(model.preferencesStatus) {
                    Text(model.preferencesStatus)
                        .foregroundStyle(ThemeColor(token: model.preferencesStatus.contains("失败") ? .modified : .secondaryText))
                        .help(model.store.url.path)
                }
                Spacer()
                if let snapshot = model.snapshot {
                    HStack(spacing: 10) {
                        if model.workingCount > 0 {
                            HStack(spacing: 5) {
                                if model.theme.style.solidMarks { StatusSquare(token: .modified) }
                                Text("工作区 \(model.workingCount)").contentTransition(.numericText())
                            }
                        }
                        if model.stagedCount > 0 {
                            HStack(spacing: 5) {
                                if model.theme.style.solidMarks { StatusSquare(token: .added) }
                                Text("暂存 \(model.stagedCount)").contentTransition(.numericText())
                            }
                        }
                        if let unpushed = snapshot.unpushed, unpushed > 0 {
                            Text("↑\(unpushed) 未推送").foregroundStyle(ThemeColor(token: .modified)).contentTransition(.numericText())
                        }
                        if let behind = snapshot.behind, behind > 0 {
                            Button(action: model.preparePull) { Text("↓\(behind) 可拉取").contentTransition(.numericText()) }
                                .buttonStyle(.pressable).disabled(model.busy)
                                .help("远端有 \(behind) 个新提交，点按预览并拉取")
                        }
                        if let operation = snapshot.operation {
                            Text("\(operation.title)中").foregroundStyle(ThemeColor(token: .modified))
                        }
                    }
                    .monospacedDigit()
                    .fontDesign(model.theme.style.instrument ? .monospaced : nil)
                    .motion(Motion.reveal, value: [model.workingCount, model.stagedCount, snapshot.unpushed ?? 0, snapshot.behind ?? 0])
                }
                if let root = model.repositoryURL {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([root]) } label: {
                        Label(root.lastPathComponent, systemImage: "folder").lineLimit(1)
                    }
                    .buttonStyle(.pressable)
                    .help("\(root.path)\n点按在 Finder 中显示")
                }
            }
            .themedFont(.caption, points: 10)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 29)
            .folmiSurface(.status)
        }
    }
}

extension FolmiModel {
    var workingCount: Int { snapshot?.files.filter(\.hasWorking).count ?? 0 }
    var stagedCount: Int { snapshot?.files.filter(\.hasStaged).count ?? 0 }
    var commitExclusion: CommitExclusion { CommitExclusion.make(snapshot?.files ?? []) }
}

@MainActor func panePlaceholder(symbol: String, title: String, detail: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 26, weight: .light))
        Text(title).themedFont(.body.weight(.medium), points: 13)
        Text(detail)
            .themedFont(.caption, points: 10)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(.secondary)
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

