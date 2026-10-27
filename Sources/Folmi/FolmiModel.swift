import AppKit
import Combine
import Foundation
import FolmiCore
import Observation
import SwiftUI

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let title: String
    let details: String
    let isError: Bool
    let projectPath: String?
}
enum FolmiContent: String, CaseIterable { case diff = "差异", editor = "编辑", allChanges = "全部改动", history = "历史", calls = "调用关系" }

@MainActor
@Observable
final class FolmiModel {
    var snapshot: RepositorySnapshot? {
        // The fingerprint covers the index, so open editors reload their gutter base when it moves.
        didSet {
            if snapshot?.fingerprint != oldValue?.fingerprint { editorWorkspace?.indexRevision &+= 1 }
            if hasSnapshot != (snapshot != nil) { hasSnapshot = snapshot != nil }
            if snapshot?.fingerprint != oldValue?.fingerprint || snapshot?.branch != oldValue?.branch { schedulePublishShared() }
            if snapshot?.head != oldValue?.head || snapshot?.ahead != oldValue?.ahead || snapshot?.upstream != oldValue?.upstream { refreshInReview() }
            if let snapshot, let path = repositoryURL?.path, RailEntry.canonical(snapshot.root.path) == RailEntry.canonical(path) {
                board.patch(path: path, snapshot: snapshot, inReview: inReviewCount)
            }
        }
    }
    /// Whether a repository is loaded. Views that only need this read it instead of `snapshot`, so a status refresh
    /// (an agent editing files) does not re-render the window root, its toolbar and the status bar.
    private(set) var hasSnapshot = false
    var repositoryURL: URL?
    var selectedFileID: String?
    var selectedFileIDs: Set<String> = []
    /// Lines added / removed per change, keyed like the change list's rows (`area:path`); only 锌莓 asks for them.
    var lineCounts: [String: LineCount] = [:]
    /// The project 从项目列表移除 is waiting to drop once the switch away from it has finished.
    @ObservationIgnored var removeAfterSwitch: String?
    var area: ChangeArea = .working
    var fileDiff: FileDiff?
    var fileDiffs: [FileDiff] = []
    var selectedLines: [String: Set<Int>] = [:]
    var draftMessage = "" { didSet { scheduleSave() } }
    var amendLast = false { didSet { scheduleSave() } }
    var busy = false
    var gitStartupState: GitStartupState = .unchecked
    var gitInstallMessage: String?
    var gitInstallerRunning = false
    @ObservationIgnored var gitCheckRunning = false
    @ObservationIgnored var startupResumed = false
    @ObservationIgnored var pendingFolmiLink: URL?
    var errorMessage: String?
    var missingProjectPath: String?
    /// A folder just picked that is not a Git repository; the alert offers to pick another one.
    var notRepositoryPath: String?
    var showCommitComposer = false
    var activity: [ActivityEntry] = []
    var isDemo = false
    var showDelivery = false
    var showPull = false
    var showStashes = false
    var stashEntries: [StashEntry] = []
    var stashFileLists: [String: [String]] = [:]
    /// Per stash, the files that would conflict if it were brought back onto the current commit (see `stashConflicts`).
    var stashConflictLists: [String: [String]] = [:]
    /// The pull sheet's state: what a pull would do (read after a fresh fetch), the chosen way, why it cannot run.
    var pullPlan: GitRepository.PullPlan?
    var pullKind: GitRepository.PullKind = .fastForward
    var pullLoading = false
    var pullProblem: String?
    /// When the last background fetch finished, and why it failed (shown in the pull sheet, never as an alert).
    var lastFetch: Date?
    var fetchProblem: String?
    @ObservationIgnored var fetchTask: Task<Void, Never>?
    @ObservationIgnored var fetching = false
    /// A pull stopped on a conflict: HEAD before it started, per project, so finishing it is still one ⌘Z.
    @ObservationIgnored var pullStartHeads: [String: PullStart] = [:]
    var showActivity = false
    var deliveryKind: DeliveryKind = .push { didSet { deliveryPlan = nil } }
    var deliveryRemote = "" { didSet { deliveryPlan = nil } }
    var deliveryBranch = "" { didSet { deliveryPlan = nil } }
    /// Branches the chosen remote has (its remote-tracking refs, as of the last fetch), for the branch menu.
    var deliveryRemoteBranches: [String] = []
    var scriptPath = "" { didSet { deliveryPlan = nil } }
    var scriptArguments = "" { didSet { deliveryPlan = nil } }
    var profileName = ""
    var selectedProfileID: UUID?
    var deliveryPlan: DeliveryPlan?
    /// When the target branch has moved on: rebase onto its latest before pushing (on by default).
    var deliveryRebaseFirst = true
    /// A delivery stopped on a rebase conflict, per project: once the rebase is finished the sheet opens again.
    @ObservationIgnored var deliveryAfterRebase: Set<String> = []
    /// A 放回 that stopped on conflicts, per project: the stash still on the list, for 撤销放回 and for dropping it
    /// once the conflicts are resolved.
    var conflictedRestores: [String: StashEntry] = [:]
    var projects: [ProjectPreferences] = []
    var editorWorkspace: EditorWorkspace?
    /// The selected terminal tab of this project.
    var terminalSession: TerminalSession?
    /// This project's terminal tabs, in order.
    var terminalTabs: [TerminalSession] = []
    var showTerminal = false { didSet { syncTerminalPane(); scheduleSave() } }
    var paneLayout = PaneLayoutState() { didSet { if paneLayout != oldValue { scheduleSave() } } }
    var paneFocusRequest: PaneFocusRequest?
    /// Review notes for every open project; they live for this app session only.
    var reviewComments: [ReviewComment] = [] { didSet { if reviewComments != oldValue { scheduleSave(); schedulePublishShared() } } }
    /// Debounced write of the state `folmi-hook mcp` reads (AgentBridge.swift).
    /// Rules worth proposing from what the user keeps turning down (Learning.swift).
    var ruleProposals: [RuleProposal] = []
    /// The last rejection, for the review page's 「写原因」 pill.
    var lastReject: RecentReject?
    /// The last ⏎ that went through, for the review page's short 「已收下」 pill.
    var lastAccept: RecentAccept?
    /// Where the review page goes after an undo or redo: the paths it put back, and when.
    var reviewFocusAfterUndo: (paths: [String], date: Date)?
    var showMemory = false
    @ObservationIgnored var sharedPublishTask: Task<Void, Never>?
    /// Size and date of each project's comment-replies.jsonl when last read.
    @ObservationIgnored var commentReplyStamps: [String: String?] = [:]
    var content: FolmiContent = .diff
    /// Every changed file in one page: staged (HEAD → index) first, then unstaged (index → work tree).
    var allChanges: [FileDiff] = []
    var allChangesLoading = false
    var allChangesNotice: String?
    /// Line selections on the all-changes page, keyed by `FileDiff.allChangesKey`: a file can be listed as both staged
    /// and unstaged, and their line IDs are unrelated.
    var allChangesSelection: [String: Set<Int>] = [:]

    // History page
    var history: [CommitNode] = []
    var historyRows: [CommitGraphRow] = []
    var historyLoading = false
    var historyRequestedLimit = FolmiModel.historyLimit
    var historyHasMore = false
    var selectedCommitID: String?
    var commitDetail: CommitDetail?
    var selectedCommitFile: String?
    var commitFileDiff: FileDiff?
    /// Set while comparing two commits: the detail then lists base → selected instead of selected against its parent.
    var compareBaseID: String?
    /// What the selected commit allows (reword, revert, cherry-pick).
    var selectedCommitAbilities: GitRepository.CommitAbilities?
    /// A rollback waiting for the user to pick how (keep the changes staged, or put the files back too).
    var rollbackPrompt: GitRepository.RollbackPlan?
    /// The open repository's working trees (main checkout first) and what each holds, for the rail's notice, the
    /// worktree sheet and the branch menu.
    var worktrees: [WorktreeStatus] = []
    @ObservationIgnored var worktreesRead: Date?
    var showWorktrees = false
    /// The 远端 sheet: the project's remotes with their addresses, read when it opens and after each change.
    var showRemotes = false
    var remoteList: [GitRemote] = []
    /// A remote waiting for the delete confirmation, with what removing it takes away.
    var remoteRemoval: RemoteRecord?
    /// 调用关系: the call graph, its center and the page's own state.
    let callMap = CallMapState()
    @ObservationIgnored var historyRequest = UUID()
    @ObservationIgnored var commitRequest = UUID()
    static let historyLimit = 500
    @ObservationIgnored var allChangesRequest = UUID()
    static let allChangesFileLimit = 300
    var fileSearch = ""
    var browserPaths: [String] = []
    var projectTree: ProjectTreeSnapshot?
    /// Ignored folders of the current tree already read or being read.
    @ObservationIgnored private var treeFolderLoads: Set<String> = []
    var treeLoading = false
    var treeError: String?
    var preferencesStatus = ""
    var showQuickOpen = false
    var showProjectSearch = false
    var projectSearchQuery = "" { didSet { scheduleSearch() } }
    var searchCaseSensitive = false { didSet { scheduleSearch() } }
    var projectSearchResult: ProjectSearchResult?
    var projectSearching = false
    var appearance: FolmiAppearance = .system { didSet { applyEditorPresentation(); scheduleSave() } }
    var theme: FolmiTheme = .standard { didSet { ThemePalette.current = theme.palette; applyEditorPresentation(); redrawAppKitViews(); scheduleSave() } }
    var glassSurfaces = true { didSet { editors.values.forEach { $0.glassSurfaces = glassSurfaces }; scheduleSave() } }
    var editorLineBlame = true { didSet { editors.values.forEach { $0.showsLineBlame = editorLineBlame }; scheduleSave() } }
    /// Line authors per open file, valid while HEAD stays the commit they were read at.
    @ObservationIgnored var blameCache: [String: FileBlame] = [:]
    var markdownDiffRendered = true { didSet { scheduleSave() } }
    var unifiedDiff = false { didSet { scheduleSave() } }
    var foldWhitespace = false { didSet { scheduleSave() } }
    var companionMotion = true { didSet { scheduleSave() } }
    /// Taken by `InboxPanel` at launch and when changed in settings, never here: test models must not grab it.
    var ideaHotKey: IdeaHotKey = .standard { didSet { scheduleSave() } }
    var editorFontSize: Double = 18 { didSet { applyEditorPresentation(); scheduleSave() } }
    /// Markdown live-preview body font ("" system, "serif"), size and reading width (0 = no limit).
    var markdownFontFamily = "" { didSet { applyEditorPresentation(); scheduleSave() } }
    var markdownFontSize: Double = 16 { didSet { applyEditorPresentation(); scheduleSave() } }
    var markdownReadingWidth: Double = 720 { didSet { applyEditorPresentation(); scheduleSave() } }

    // Review flow (MVP-0): undo, review progress, the pre-written commit message.
    /// Seen changed lines of the open project; see `ReviewProgress`.
    var reviewLedger = ReviewLedger()
    /// Labels of the next Git undo / redo of the open project, for menus and the review page.
    var undoLabel: String?
    var redoLabel: String?
    @ObservationIgnored var undoStacks: [String: [UndoEntry]] = [:]
    @ObservationIgnored var redoStacks: [String: [UndoEntry]] = [:]
    var commitSuggestion = CommitSuggestion.idle
    /// The draft text the app filled in itself; a draft the user typed is never replaced.
    @ObservationIgnored var autoDraft: String?
    @ObservationIgnored var suggestionTask: Task<Void, Never>?
    @ObservationIgnored var suggestionKey: String?
    var aiSettings = AISettings() {
        didSet {
            guard aiSettings != oldValue, !restoring, !applyingSavedAISettings else { return }
            do { try AISettingsStore.save(aiSettings) } catch { report(error, title: "AI 设置没有保存") }
        }
    }
    @ObservationIgnored var applyingSavedAISettings = false
    var showAISettings = false
    var showSettings = false
    /// The commit just made, shown briefly as "✓ 3f2a1c9".
    var lastCommit: CommitToast?
    /// Today's review counts and the day streak, for the wrap-up card (DailyStats.swift).
    var dailyStats = DailyStats()
    /// The keyboard cheat sheet: shown while ⌘ is held alone, or pinned with ⌘/.
    var showShortcuts: ShortcutSheetState = .hidden {
        didSet { if showShortcuts != .hidden { completeTour(.shortcuts) } }
    }
    /// 试一试 in demo projects (Tour.swift).
    var tour = TourState()
    /// The 大仓库模式 offer above the cards (LargeRepository.swift).
    var largeRepositoryOffer = false
    var lastSlowStatus: TimeInterval = 0
    @ObservationIgnored var slowStatusCount = 0
    func toggleShortcuts() { withMotion(.easeOut(duration: 0.12)) { showShortcuts = showShortcuts == .pinned ? .hidden : .pinned } }
    @ObservationIgnored var savedSnapshotFingerprint: String?
    /// Projects whose terminal tabs were all closed: reopening starts one fresh tab.
    @ObservationIgnored var terminalTabsCleared: Set<String> = []
    /// Displayed diffs keyed by snapshot fingerprint, area and path; a new snapshot fingerprint starts over.
    @ObservationIgnored var diffCache: [String: FileDiff] = [:]
    @ObservationIgnored var diffCacheFingerprintValue: String?
    @ObservationIgnored var prefetchTaskValue: Task<Void, Never>?

    // ⌘K, the Markdown index, tasks.
    var showPalette = false
    var showTasks = false
    var showHooksSetup = false
    // AI activity from Claude Code hooks.
    var aiBatches: [AIBatch] = []
    /// 全部改动 narrowed to one AI turn (its id), or nil for everything.
    var turnFilter: String?
    /// Commits ahead of the upstream that are already up for review on Gerrit (see `refreshInReview`).
    var inReviewCount = 0
    var capsule: AIActivityCapsule?
    @ObservationIgnored var dismissedCapsule: String?
    @ObservationIgnored var aiBatchStore: [String: [AIBatch]] = [:]
    @ObservationIgnored var aiEventOffsets: [String: UInt64] = [:]
    /// How much of each project's hook-errors.log has been shown.
    @ObservationIgnored var hookErrorOffsets: [String: UInt64] = [:]
    /// Shown once when a project opens with changes not looked at yet.
    var openingBanner: String?
    var aiAssist: AIAssistState?
    /// All projects and worktrees, for the menu bar and the overview.
    let board = ProjectBoard()
    /// New Folmi versions; checking starts from the app's window task, so tests never reach the network.
    let updater = AppUpdater()
    var showOverview = false
    var showDocHistory = false
    /// A note being written on text selected in the Markdown reader.
    var readerCommentDraft: ReaderCommentDraft?
    /// A branch or tag action waiting for a name or a yes.
    var refPrompt: RefPrompt?
    /// The right card shows the AI tab instead of the selected terminal.
    var aiTabSelected = false
    /// The AI tab's conversation with Claude or Codex (AgentSession.swift), its draft and attached context.
    var agentSession: AgentSession?
    var agentDraft = ""
    var agentContext: [AgentContext] = []
    /// Pre-commit check of what is staged; a blocking finding needs a second ⌘⏎.
    var commitCheck: CommitCheck?
    /// Staged hunks nobody accepted, per file: an agent's or the terminal's `git add`, a merge. Empty until the staged
    /// check of the current snapshot has run.
    var unreviewedStaged: [String: Int] {
        guard let check = commitCheck, check.fingerprint == snapshot?.fingerprint else { return [:] }
        return check.unreviewed(reviewLedger)
    }
    @ObservationIgnored var commitCheckTask: Task<Void, Never>?
    @ObservationIgnored var commitCheckOverride: String?
    /// Commit was pressed and waits for the pre-commit check of what is staged.
    var commitCheckWaiting = false
    @ObservationIgnored var assistTask: Task<Void, Never>?
    @ObservationIgnored var paletteItemsCache: [PaletteItem] = []
    /// Files, headings and tasks for ⌘K, built off the main thread whenever the tree or the index changes.
    @ObservationIgnored var paletteStaticItems: [PaletteItem] = []
    @ObservationIgnored var paletteStaticTask: Task<Void, Never>?
    @ObservationIgnored var paletteUsage = PaletteUsage()
    /// Headings and tasks of the open project's Markdown files.
    var markdownIndex: MarkdownIndex?
    @ObservationIgnored var markdownIndexRoot: URL?
    @ObservationIgnored var markdownIndexTask: Task<Void, Never>?
    @ObservationIgnored var readerPrefetchTask: Task<Void, Never>?
    @ObservationIgnored var terminalHoverTask: Task<Void, Never>?

    let store: WorkspaceStore
    @ObservationIgnored var preferences = WorkspacePreferences()
    @ObservationIgnored var repository: GitRepository?
    @ObservationIgnored var commandEnvironment: [String: String] = [:]
    @ObservationIgnored var diffRequest = UUID()
    @ObservationIgnored var diffSwitchStart: ContinuousClock.Instant?
    @ObservationIgnored private var treeRequest = UUID()
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var saveDeadline: ContinuousClock.Instant?
    @ObservationIgnored var restoring = true
    @ObservationIgnored var editors: [String: EditorWorkspace] = [:]
    @ObservationIgnored var terminals: [String: [TerminalSession]] = [:]
    @ObservationIgnored var selectedTerminals: [String: UUID] = [:]
    /// Each project's terminal columns (向左拆分 / 向右拆分), holding its session ids.
    var terminalColumns: [String: PaneColumns] = [:]
    /// Whether the editor and terminal cards are wide enough for one more column.
    var splitRoom: [FolmiPane: Bool] = [:]
    @ObservationIgnored var editorObservers: [String: AnyCancellable] = [:]
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var searchWorker: Task<ProjectSearchResult, Error>?
    @ObservationIgnored var searchRevision = UUID()
    let autoRefresh: Bool
    @ObservationIgnored private var watcher: RepositoryWatcher?
    @ObservationIgnored private var activationObserver: AnyCancellable?
    @ObservationIgnored private var backgroundRefreshing = false
    @ObservationIgnored private var backgroundRefreshPending = false
    /// A refresh that was asked for while another ran needs the ref reads too (not only work tree files changed).
    @ObservationIgnored private var pendingFullRefresh = false
    /// Number of background refreshes that found a real change and updated the snapshot.
    @ObservationIgnored private(set) var autoRefreshCount = 0

    /// `autoRefresh` watches the open repository and re-checks status when the app becomes active; the app turns it on, tests opt in.
    init(store: WorkspaceStore = WorkspaceStore(url: RuntimeOptions.workspaceURL), autoRefresh: Bool = false,
         checkEnvironmentOnStartup: Bool = false) {
        self.store = store
        self.autoRefresh = autoRefresh
        if checkEnvironmentOnStartup { gitStartupState = .checking }
        // Caches, AI settings and ⌘K history sit next to the settings file this model uses (a test's own folder).
        AppFiles.directory = store.url.deletingLastPathComponent()
        aiSettings = AISettingsStore.load()
        paletteUsage = PaletteUsage.load()
        dailyStats = DailyStats.load()
        tour = TourState.load()
        if autoRefresh {
            let helper = HooksInstaller.installedHelper
            Task.detached(priority: .utility) {
                do { try HooksInstaller.refreshInstalledHelper(destination: helper) }
                catch { AppLog.failure("更新 Claude 钩子程序失败", error) }
            }
        }
        do {
            preferences = try store.load()
            if !FileManager.default.fileExists(atPath: store.url.path) {
                preferences.editorFontSize = 18
                preferences.appearance = .dark
            }
            editorFontSize = preferences.editorFontSize
            markdownFontFamily = preferences.markdownFontFamily
            markdownFontSize = preferences.markdownFontSize
            markdownReadingWidth = preferences.markdownReadingWidth
            appearance = preferences.appearance
            theme = preferences.theme
            ThemePalette.current = theme.palette
            glassSurfaces = preferences.glassSurfaces
            editorLineBlame = preferences.editorLineBlame
            markdownDiffRendered = preferences.markdownDiffRendered
            unifiedDiff = preferences.unifiedDiff
            foldWhitespace = preferences.foldWhitespace
            companionMotion = preferences.companionMotion
            ideaHotKey = preferences.ideaHotKey
            projects = preferences.projects
            reviewComments = projects.flatMap(\.reviewComments)
            paneLayout = preferences.paneLayout
            showTerminal = preferences.showTerminal
            syncTerminalPane()
            preferencesStatus = "配置已载入"
        } catch {
            errorMessage = error.localizedDescription
            PerfLog.note("error", "配置读取失败: \(error.localizedDescription)")
            preferencesStatus = "配置读取失败，原文件保留"
        }
        restoring = false
        PerfLog.mark("launch.modelInit")
        if autoRefresh {
            activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in self?.refreshInBackground() }
        }
    }
    var repositoryTitle: String {
        projects.first { $0.rootPath == repositoryURL?.path }?.name ?? repositoryURL?.lastPathComponent ?? "Folmi"
    }
    var filesInArea: [FileChange] { snapshot?.files.filter { area == .working ? $0.hasWorking : $0.hasStaged } ?? [] }
    var visibleFiles: [FileChange] { visibleFiles(in: area) }
    func visibleFiles(in group: ChangeArea) -> [FileChange] {
        (snapshot?.files ?? []).filter { (group == .working ? $0.hasWorking : $0.hasStaged) && (fileSearch.isEmpty || $0.path.localizedCaseInsensitiveContains(fileSearch)) }
    }
    var visibleBrowserPaths: [String] { browserPaths.filter { fileSearch.isEmpty || $0.localizedCaseInsensitiveContains(fileSearch) } }
    var selectedFile: FileChange? { filesInArea.first { $0.id == selectedFileID } }
    var profiles: [DeliveryProfile] { projects.first { $0.rootPath == repositoryURL?.path }?.deliveryProfiles ?? [] }
    var currentActivity: [ActivityEntry] { activity.filter { $0.projectPath == repositoryURL?.path } }
    var canCommit: Bool {
        !busy && !commitCheckWaiting && !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && snapshot != nil &&
        !(snapshot?.files.contains(where: \.isConflict) ?? true) &&
        ((snapshot?.files.contains(where: \.hasStaged) ?? false) || (amendLast && snapshot?.head != nil))
    }
    /// Something is being prepared for a commit (staged files, a message, or an amend), so the commit box offers
    /// committing rather than pushing.
    var isComposingCommit: Bool {
        amendLast || (snapshot?.files.contains(where: \.hasStaged) ?? false) || !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canDeliver: Bool { !busy && deliveryPlan?.formSignature == formSignature && deliveryPlan?.root == repositoryURL }
    /// Where the planned delivery goes, read before the command itself: one label and value per row.
    var deliverySummary: [(label: String, value: String)] {
        guard let plan = deliveryPlan else { return [] }
        var rows = [("项目", repositoryTitle), ("提交", plan.head), ("推到", plan.endpoint ?? "本地脚本")]
        if plan.kind != .script { rows.append(("分支", (plan.kind == .gerrit ? "refs/for/" : "refs/heads/") + deliveryBranch)) }
        if let base = plan.base {
            rows.append(("远端", plan.behind == 0
                ? "\(base.name) 是 \(base.commit.prefix(7))，你的提交已经在它之上"
                : "\(base.name) 有 \(plan.behind) 个新提交你这里没有（最新 \(base.commit.prefix(7))）"))
        } else if let problem = plan.baseProblem {
            rows.append(("远端", problem))
        }
        rows.append(("目录", plan.root.path))
        return rows
    }
    /// The exact command of the plan; empty before 预览命令.
    var deliveryCommandsText: String {
        guard let plan = deliveryPlan else { return "" }
        guard plan.rebaseNeeded, deliveryRebaseFirst, let base = plan.base else { return plan.command.display }
        let push = DeliveryCommand(executable: plan.command.executable, arguments: plan.command.arguments.map { $0 == "\(plan.head):\(plan.target)" ? "<变基后的提交>:\(plan.target)" : $0 })
        return "'/usr/bin/git' 'rebase' '\(base.commit)'\n" + push.display
    }
    var formSignature: String { [deliveryKind.rawValue, deliveryRemote, deliveryBranch, scriptPath, scriptArguments].joined(separator: "\0") }
    var colorScheme: ColorScheme? { appearance == .system ? nil : (appearance == .dark ? .dark : .light) }
    var editorWrapLines: Bool {
        get { editorWorkspace?.presentation.wrapLines ?? preferences.editorWrapLines }
        set {
            preferences.editorWrapLines = newValue
            applyEditorPresentation()
            scheduleSave()
        }
    }
    var editorPresentation: EditorPresentation {
        EditorPresentation(fontFamily: preferences.editorFontFamily, fontSize: editorFontSize,
                           lineHeight: max(editorFontSize, preferences.editorLineHeight), tabSize: preferences.editorTabSize,
                           wrapLines: preferences.editorWrapLines, appearance: appearance, theme: theme,
                           proseFontFamily: markdownFontFamily, proseFontSize: markdownFontSize, readingWidth: markdownReadingWidth)
    }
    /// What the rest of the window shows from the current editor (tabs, dirty dots, selection, outline). The editor is
    /// an ObservableObject the window does not observe, so views read this instead; it only changes when the chrome
    /// does, so text, caret and scroll changes stay inside the editor card.
    private(set) var editorChrome: EditorWorkspace.ChromeSignature?
    private func syncEditorChrome() {
        let signature = editorWorkspace?.chromeSignature
        if editorChrome != signature { editorChrome = signature }
    }
    var isMarkdownDocument: Bool {
        _ = editorChrome // tracking only: the live editor value below is never a run-loop turn behind
        return ["md", "markdown", "mdown"].contains((editorWorkspace?.selectedDocumentID as NSString?)?.pathExtension.lowercased() ?? "")
    }
    /// AppKit views that draw with `ThemePalette.current` (diff canvas, gutter) repaint when the theme changes.
    private func redrawAppKitViews() {
        func mark(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(mark) }
        NSApp?.windows.forEach { if let view = $0.contentView { mark(view) } }
    }
    private func applyEditorPresentation() {
        let presentation = editorPresentation
        for editor in editors.values where editor.presentation != presentation { editor.presentation = presentation }
    }
    func changeFontSize(_ delta: Double) { editorFontSize = min(40, max(8, editorFontSize + delta)) }
    func toggleMarkdownPreview() {
        guard !busy, isMarkdownDocument else { return }
        editorWorkspace?.markdownReading.toggle()
    }

    /// Whether launch reopens a Markdown document in reading mode: then the reader is the first screen and WebKit
    /// should start with the window instead of after it.
    var restoresMarkdownReader: Bool {
        guard preferences.markdownReading, snapshot == nil, let path = preferences.selectedProjectPath,
              let project = savedProject(path), (project.lastContent ?? FolmiContent.editor.rawValue) == FolmiContent.editor.rawValue,
              let selected = project.selectedEditorPath else { return false }
        return EditorWorkspace.isMarkdownPath(selected)
    }
    func restoreStartup() {
        guard snapshot == nil, !busy, let path = preferences.selectedProjectPath,
              let project = projects.first(where: { $0.rootPath == path }) else { return }
        // Reload saved editor files read-only; a restored real project does not auto-run a login shell.
        if !project.isDemo { showTerminal = false }
        switchProject(path)
    }
    func openRepository() {
        guard !busy, !gitStartupState.blocksGit else { return }
        let panel = NSOpenPanel()
        panel.title = "添加 Git 项目"; panel.prompt = "添加"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func loadDemo() {
        guard !busy, !gitStartupState.blocksGit else { return }
        do { try savePreferencesNow() } catch { report(error, title: "保存配置失败"); return }
        busy = true
        Task {
            do {
                let demo = try await DemoRepository.create(includeNavigationSamples: true, remoteUpdates: true)
                try await installRepository(demo.root, environment: demo.environment, demo: true)
                record("演示项目已创建", "\(demo.root.path)\n远程 demo 是本地临时裸仓库；终端也使用隔离环境。")
                try savePreferencesNow()
            } catch { report(error, title: "创建演示项目失败") }
            busy = false
        }
    }
    func open(_ url: URL, environment: [String: String] = [:], demo: Bool = false) {
        guard !busy, !gitStartupState.blocksGit else { return }
        guard projectPathIsAvailable(url) else { return }
        PerfLog.mark("launch.openCalled")
        do { try savePreferencesNow() } catch { report(error, title: "保存配置失败"); return }
        busy = true
        // A project opened before is drawn from its last saved status first; the real status follows at once.
        let cached = SnapshotCache.load(root: url.standardizedFileURL.path)
        PerfLog.mark(cached == nil ? "launch.cacheMiss" : "launch.cacheHit")
        Task {
            PerfLog.mark("launch.taskStarted")
            do {
                try await installRepository(url, environment: environment, demo: demo, cached: cached)
                try savePreferencesNow()
                finishPendingRemoval()
                await loadWorktrees()
            } catch let error where FolmiModel.isNotRepository(error) { reportNotRepository(url) }
            catch { report(error, title: "打开项目失败") }
            busy = false
            // The saved status is replaced right away; a project that can no longer be read says so.
            if cached != nil { refreshInBackground(reportingErrors: true) }
        }
    }
    func switchProject(_ path: String) {
        guard !busy, !gitStartupState.blocksGit, path != repositoryURL?.path, let project = projects.first(where: { $0.rootPath == path }) else { return }
        lastReject = nil; lastAccept = nil; reviewFocusAfterUndo = nil
        open(URL(fileURLWithPath: path), environment: project.environment, demo: project.isDemo)
    }
    private func installRepository(_ url: URL, environment: [String: String], demo: Bool, cached: RepositorySnapshot? = nil) async throws {
        // Set at creation: an `await` on the new actor here would hand the main thread to queued work (WebKit's
        // warm-up) before the first diff, ~150 ms at launch.
        let key = SnapshotCache.key(url.path)
        let large = projects.first { SnapshotCache.key($0.rootPath) == key }.flatMap { savedProject($0.rootPath) }?.largeRepository ?? false
        let candidate = GitRepository(url: url, environment: environment, largeRepository: large)
        let state: RepositorySnapshot
        if let cached { state = cached } else { state = try await candidate.load() }
        PerfLog.mark("launch.repoLoaded")
        restoring = true
        defer { restoring = false }
        cancelProjectSearch()
        projectSearchQuery = ""
        projectSearchResult = nil
        repository = candidate; commandEnvironment = environment; repositoryURL = state.root; snapshot = state; isDemo = demo
        if !projects.contains(where: { $0.rootPath == state.root.path }) {
            let name = demo ? "演示项目 \(projects.filter(\.isDemo).count + 1)" : state.root.lastPathComponent
            var project = ProjectPreferences(rootPath: state.root.path, name: name, isDemo: demo, environment: demo ? environment : [:])
            if demo {
                let profile = DeliveryProfile(name: "演示本地推送", kind: .push, remote: "demo", branch: "main")
                project.deliveryProfiles = [profile]; project.selectedProfileID = profile.id
            }
            projects.append(project)
        }
        let settings = savedProject(state.root.path)!
        largeRepositoryOffer = false; slowStatusCount = 0
        area = ChangeArea(rawValue: settings.lastArea) ?? .working
        selectedFileID = nil; selectedFileIDs = []; fileDiff = nil; fileDiffs = []; selectedLines = [:]; fileSearch = ""
        draftMessage = settings.draftMessage; amendLast = settings.amendLast
        if let profile = settings.deliveryProfiles.first(where: { $0.id == settings.selectedProfileID }) { applyProfile(profile) }
        else {
            selectedProfileID = nil; profileName = ""; deliveryKind = .push
            deliveryRemote = state.remotes.contains("origin") ? "origin" : (state.remotes.first ?? "")
            deliveryBranch = ""; scriptPath = ""; scriptArguments = ""
        }
        deliveryPlan = nil
        if editors[state.root.path] == nil {
            let editor = EditorWorkspace(root: state.root)
            editor.presentation = editorPresentation
            editor.glassSurfaces = glassSurfaces
            editor.showsLineBlame = editorLineBlame
            editor.markdownReading = preferences.markdownReading
            editor.showsOutline = preferences.markdownOutline
            editor.outlineWidth = preferences.markdownOutlineWidth
            editor.restoreSession(tabs: settings.editorTabs, selectedPath: settings.selectedEditorPath, columns: settings.editorColumns)
            editors[state.root.path] = editor
            // Only what the rest of the window shows from the editor is forwarded; text, caret and scroll changes stay
            // inside the editor card instead of re-rendering the diff, file tree and terminal on every keystroke.
            editorObservers[state.root.path] = editor.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self, weak editor] _ in
                    guard let self, let editor else { return }
                    if editor === self.editorWorkspace { self.syncEditorChrome() }
                    self.scheduleSave()
                }
            editor.onSessionChange = { [weak self] in self?.scheduleSave() }
            editor.sendSelectionToTerminal = { [weak self] range in self?.sendEditorSelectionToTerminal(selection: range) }
            editor.sendTextToTerminal = { [weak self] text, reference in self?.sendTextToTerminal(text, reference: reference) }
            editor.assistSelection = { [weak self] mode, text, source in self?.assist(mode, text: text, source: source) }
            editor.commentSelection = { [weak self] path, first, last, quote in
                self?.readerCommentDraft = ReaderCommentDraft(path: path, firstLine: first, lastLine: last, quote: quote)
            }
            editor.showChanges = { [weak self] path in self?.showChanges(of: path) }
            editor.showCallsAt = { [weak self] path, text, location in self?.showCalls(path: path, text: text, location: location) }
            editor.showCommit = { [weak self] id in
                guard let self else { return }
                self.showContent(.history)
                Task { await self.selectCommit(id) }
            }
        }
        editorWorkspace = editors[state.root.path]
        syncEditorChrome()
        editorWorkspace?.loadIndexBase = { path in
            guard let file = try? await candidate.indexFile(path: path) else { return nil }
            return IndexBase(file)
        }
        editorWorkspace?.stageIndexText = { [weak self] base, data in self?.stageEditorChange(base: base, data: data) }
        blameCache = [:]
        editorWorkspace?.loadBlame = { [weak self] path in
            guard let self else { return .unavailable }
            let head = self.snapshot?.head
            if let cached = self.blameCache[path], cached.head == head { return .blame(cached) }
            do {
                guard let blame = try await candidate.blame(path: path) else { return .notInHead }
                if self.blameCache.count >= 24 { self.blameCache = [:] }
                self.blameCache[path] = blame
                return .blame(blame)
            } catch { return .unavailable }
        }
        editorWorkspace?.loadLineHistory = { path, first, last in
            (try? await candidate.lineHistory(path: path, first: first, last: last)) ?? []
        }
        editorWorkspace?.indexRevision &+= 1
        projectTree = nil
        treeError = nil
        allChangesRequest = UUID(); allChanges = []; allChangesNotice = nil; allChangesSelection = [:]
        historyRequest = UUID(); commitRequest = UUID(); history = []; historyRows = []
        historyRequestedLimit = Self.historyLimit; historyHasMore = false
        showCommitComposer = false
        selectedCommitID = nil; commitDetail = nil; selectedCommitFile = nil; commitFileDiff = nil; compareBaseID = nil
        loadReviewLedger(); syncUndoLabels()
        commitSuggestion = .idle; suggestionKey = nil; autoDraft = nil
        // Back where it was: the page and the selected change of last time.
        let saved = FolmiContent(rawValue: settings.lastContent ?? "")
        let hasEditor = editorWorkspace?.documents.isEmpty == false
        content = saved.map { $0 == .editor && !hasEditor ? .diff : $0 } ?? (hasEditor ? .editor : .diff)
        commitCheck = nil; commitCheckOverride = nil
        if let path = settings.selectedChangePath, let change = state.files.first(where: { $0.path == path }) {
            selectedFileIDs = [change.id]; selectedFileID = change.id
        }
        syncTerminalTabs()
        if showTerminal { startTerminal() }
        // The file tree is read beside the first diff instead of before it.
        PerfLog.mark("launch.diffStart")
        async let tree: Void = refreshProjectTree()
        await updateDiff()
        PerfLog.mark("launch.diffReady")
        PerfLog.markAfterFrame("launch.firstContentFrame")
        if content == .allChanges { await loadAllChanges() } else if content == .history { await loadHistory() }
        await tree
        PerfLog.mark("launch.treeReady")
        await relocateReviewComments()
        await startWatching(candidate, root: state.root)
        startBackgroundFetch()
        aiBatches = aiBatchStore[state.root.path] ?? []
        turnFilter = nil
        readAIEvents(); pruneAIBatches()
        refreshLearning()
        scheduleCommitSuggestion()
        scheduleCommitCheck()
        Task { await prepareOpeningBanner() }
        if PerfLog.scripted { runPerfScript() }
    }
    private func startWatching(_ repository: GitRepository, root: URL) async {
        watcher = nil
        guard autoRefresh else { return }
        let directories: [URL]
        do { directories = try await repository.watchedDirectories() }
        catch { AppLog.failure("没能开始监听文件变化，改动不会自动刷新", error); return }
        guard repositoryURL == root else { return }
        watcher = RepositoryWatcher(directories: directories) { [weak self] gitChanged in
            MainActor.assumeIsolated { self?.refreshInBackground(worktreeOnly: !gitChanged) }
        }
    }
    /// Quietly re-reads Git status after outside changes (terminal, other tools, focus return).
    /// Nothing is replaced when the status is unchanged; line selections survive when their file's diff is unchanged.
    /// `worktreeOnly`: the watcher saw only work tree files change, so branches, commits and stashes are kept when
    /// HEAD and the upstream still match (one `git status` instead of six commands).
    func refreshInBackground(reportingErrors: Bool = false, worktreeOnly: Bool = false) {
        guard !gitStartupState.blocksGit, let repository, let root = repositoryURL else { return }
        guard !busy, !showDelivery, !backgroundRefreshing else {
            backgroundRefreshPending = true
            if !worktreeOnly { pendingFullRefresh = true }
            return
        }
        let reuse = worktreeOnly && !pendingFullRefresh ? snapshot : nil
        pendingFullRefresh = false
        backgroundRefreshing = true
        backgroundRefreshPending = false
        readAIEvents()
        // Open files follow the disk first: the agent in the terminal edits them, and the reader should show its result.
        if editorWorkspace?.reloadCleanDocuments().isEmpty == false { editorWorkspace?.indexRevision &+= 1 }
        if !worktreeOnly { Task { await loadWorktrees() } }
        Task {
            defer {
                backgroundRefreshing = false
                if backgroundRefreshPending { refreshInBackground(worktreeOnly: true) }
            }
            let interval = Perf.signposter.beginInterval("Git status refresh")
            let loaded: RepositorySnapshot?
            do { loaded = try await repository.load(reusing: reuse) }
            catch {
                loaded = nil
                if reportingErrors, repositoryURL == root { report(error, title: "读取项目失败，显示的是上次保存的状态") }
            }
            Perf.signposter.endInterval("Git status refresh", interval)
            if loaded != nil, repositoryURL == root { noteStatusDuration(await repository.lastStatusDuration) }
            guard let next = loaded, repositoryURL == root, !busy, let current = snapshot else { return }
            guard next.fingerprint != current.fingerprint || next.branch != current.branch || next.head != current.head ||
                  next.branches != current.branches || next.remotes != current.remotes else { return }
            let pathsChanged = Set(next.files.map(\.path)) != Set(current.files.map(\.path))
            if next.head != current.head || next.fingerprint != current.fingerprint { deliveryPlan = nil }
            noteExternalChanges(from: current, to: next)
            let applied = ContinuousClock.now
            PerfLog.resetBodies()
            snapshot = next
            autoRefreshCount += 1
            scheduleCommitSuggestion()
            scheduleCommitCheck()
            scheduleMarkdownIndex()
            scheduleReaderPrefetch()
            await updateDiff(keepingSelection: true)
            if content == .allChanges { await loadAllChanges() }
            if content == .history, next.head != current.head || next.branches != current.branches { await loadHistory() }
            await relocateReviewComments()
            if pathsChanged { await refreshProjectTree() }
            PerfLog.afterFrame { PerfLog.interval("switch.refreshFrame", since: applied) }
        }
    }
    /// Changed and open Markdown files are what gets read next once the agent stops; they are rendered quietly in the
    /// background so opening one is as quick as coming back to it.
    func scheduleReaderPrefetch() {
        guard let root = repositoryURL, let files = snapshot?.files else { return }
        let changed = files.filter { $0.worktreeCode != "D" && $0.indexCode != "D" && EditorWorkspace.isMarkdownPath($0.path) }.map(\.path)
        let open = (editorWorkspace?.documents ?? []).filter { EditorWorkspace.isMarkdownPath($0.id) }.map { (path: $0.id, text: $0.text) }
        let openIDs = Set(open.map(\.path))
        let paths = Array(changed.filter { !openIDs.contains($0) }.prefix(ReaderRenderCache.maximumPrefetch))
        readerPrefetchTask?.cancel()
        readerPrefetchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let read = await Task.detached(priority: .utility) { () -> [(path: String, text: String)] in
                paths.compactMap { path in
                    let url = root.appendingPathComponent(path)
                    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 512 * 1024,
                          let data = try? Data(contentsOf: url), let text = EditorWorkspace.readerText(data) else { return nil }
                    return (path, text)
                }
            }.value
            guard let self, !Task.isCancelled, self.repositoryURL == root else { return }
            ReaderRenderCache.prefetch(open + read)
        }
    }
    func refresh() {
        guard !busy, repository != nil else { return }
        busy = true
        Task { do { try await reload() } catch { report(error, title: "刷新失败") }; busy = false }
    }
    func reload() async throws {
        guard let repository else { return }
        editorWorkspace?.reloadCleanDocuments()
        snapshot = try await repository.load()
        scheduleCommitSuggestion()
        scheduleCommitCheck()
        await refreshProjectTree()
        deliveryPlan = nil
        await updateDiff()
        if content == .allChanges { await loadAllChanges() }
        if content == .history { await loadHistory() }
        await relocateReviewComments()
    }

    // MARK: Commit actions (history page)

    /// A click on the window outside an open sheet closes it, like a popover.
    func dismissSheets() {
        showDelivery = false; showPull = false; showStashes = false; showActivity = false; showAISettings = false; showPalette = false; showHooksSetup = false; showMemory = false; showWorktrees = false; showRemotes = false
        showTasks = false; showOverview = false; showDocHistory = false; readerCommentDraft = nil; showQuickOpen = false; showProjectSearch = false; showSettings = false
    }
    /// The file tree's 看改动: the change's diff, in the area that has it.
    func showChanges(ofPath path: String) {
        guard !busy, let change = snapshot?.files.first(where: { $0.path == path }) else { return }
        area = change.hasWorking ? .working : .staged
        selectFile(change)
        focusPane(.editor)
    }
    /// The editor gutter's "暂存这段": the new index content was built from the index version the gutter compared against.
    func stageEditorChange(base: IndexBase, data: Data) {
        guard let repository else { return }
        mutateUndoable("暂存编辑器中的改动段", capture: { try await repository.captureIndex([base.path]) }) {
            try await repository.replaceIndexFile(path: base.path, data: data, expectedObject: base.object)
            return base.path
        }
    }
    func editPath(_ path: String) {
        guard !busy, let editorWorkspace else { return }
        let start = ContinuousClock.now
        defer { PerfLog.spend("model.editPath", since: start) }
        do {
            try editorWorkspace.open(path: path)
            content = .editor
            targetDiff(path: path)
        } catch { report(error, title: "打开文件失败") }
    }
    func showContent(_ requested: FolmiContent) {
        if requested == .allChanges { completeTour(.review) }
        guard !busy else { return }
        if requested == .allChanges {
            if capsule != nil, aiBatches.last(where: \.isRunning) == nil { dismissCapsule() }
            openingBanner = nil
            content = .allChanges
            Task { await loadAllChanges() }
            return
        }
        if requested == .calls { showCallMap(); return }
        if requested == .history {
            content = .history
            Task { await loadHistory() }
            return
        }
        if requested == .editor {
            if editorWorkspace?.documents.isEmpty == true { editSelectedFiles() }
            else { content = .editor }
        } else {
            // With a 差异 column beside the files, 差异 only moves to that column; the diff keeps what it shows.
            if content == .editor, editorWorkspace?.columns.hasDiff != true, let path = editorWorkspace?.selectedDocumentID,
               selectedFileIDs.count <= 1 || !selectedFileIDs.contains(path) { targetDiff(path: path) }
            content = .diff
        }
    }
    /// "查看改动" from the editor: the file's diff in the editor card.
    func showChanges(of path: String) {
        guard !busy else { return }
        targetDiff(path: path)
        content = .diff
        editorWorkspace?.dismissExternalChange(path)
    }
    func targetDiff(path: String) {
        if let change = snapshot?.files.first(where: { $0.path == path }) {
            area = change.hasWorking ? .working : .staged
            selectedFileIDs = [change.id]
            selectedFileID = change.id
            Task { await updateDiff() }
        } else {
            diffRequest = UUID()
            selectedFileIDs = []
            selectedFileID = path
            selectedLines = [:]
            fileDiff = nil
            fileDiffs = []
        }
    }
    func editSelectedFiles() {
        guard !busy, let editorWorkspace else { return }
        let files = visibleFiles.filter { selectedFileIDs.contains($0.id) }
        do {
            for file in files { try editorWorkspace.open(path: file.path) }
            content = .editor
        } catch { report(error, title: "打开文件失败") }
    }
    private func refreshProjectTree() async {
        guard let root = repositoryURL else { return }
        let request = UUID()
        treeRequest = request
        treeLoading = true
        defer { if treeRequest == request { treeLoading = false } }
        do {
            // Without Git's answer the tree still works; only the fixed dependency folders are then treated as ignored.
            let ignored = (try? await repository?.ignoredPaths(in: root)) ?? IgnoredPaths()
            let result = try await Task.detached(priority: .utility) { try ProjectFileTree.scan(root: root, ignored: ignored) }.value
            guard treeRequest == request, repositoryURL == root else { return }
            projectTree = result
            // Folders read before the rescan are read again, parents first, so an open ignored folder stays filled.
            let reopened = treeFolderLoads.sorted { $0.count < $1.count }
            treeFolderLoads = []
            loadTreeFolders(reopened)
            treeError = nil
            // Search and quick open skip ignored files, as Git does.
            func paths(_ nodes: [ProjectFileNode]) -> [String] {
                nodes.flatMap { $0.isIgnored ? [] : $0.isDirectory ? paths($0.children ?? []) : [$0.path] }
            }
            browserPaths = paths(result.roots)
            scheduleMarkdownIndex()
            schedulePaletteItems()
        } catch {
            guard treeRequest == request else { return }
            projectTree = nil
            browserPaths = []
            treeError = error.localizedDescription
        }
    }
    /// Fills in an ignored folder of the file tree when it is first opened.
    func loadTreeFolder(_ path: String) { loadTreeFolders([path]) }

    /// Reads folders one after another, so a subfolder is filled in after the folder holding it.
    private func loadTreeFolders(_ paths: [String]) {
        let paths = paths.filter { treeFolderLoads.insert($0).inserted }
        guard let root = repositoryURL, !paths.isEmpty else { return }
        let request = treeRequest
        Task {
            for path in paths {
                let loaded: ProjectTreeSnapshot
                do {
                    loaded = try await Task.detached(priority: .userInitiated) { try ProjectFileTree.loadFolder(root: root, path: path) }.value
                } catch {
                    loaded = ProjectTreeSnapshot(roots: [], fileCount: 0, isTruncated: false,
                                                 notice: "无法读取此目录：\(error.localizedDescription)")
                }
                // A rescan since then replaced the tree and reads its open folders itself.
                guard treeRequest == request, repositoryURL == root, let tree = projectTree else { return }
                projectTree = ProjectTreeSnapshot(roots: ProjectFileTree.replacingChildren(in: tree.roots, path: path, with: loaded),
                                                  fileCount: tree.fileCount, isTruncated: tree.isTruncated, notice: tree.notice)
            }
        }
    }
    func fileDidSave() { refresh() }
    /// Focus a card from the keyboard or rail: reopens it if collapsed and moves keyboard focus into it.
    func focusPane(_ pane: FolmiPane) {
        guard snapshot != nil else { return }
        if pane == .terminal && !showTerminal { showTerminal = true; startTerminal() }
        paneLayout.focus(pane)
        paneFocusRequest = PaneFocusRequest(pane: pane)
    }
    /// Shows the left block's file tree or changes tab, opening and focusing the block.
    func showSideTab(_ tab: SideTab) {
        if paneLayout.sideTab != tab { paneLayout.sideTab = tab }
        if !paneLayout.isShown(.changes) || paneLayout.focused != .changes { focusPane(.changes) }
    }
    /// A click landed inside a card; keyboard focus already followed the click.
    func notePaneClicked(_ pane: FolmiPane) {
        if paneLayout.focused != pane { paneLayout.focused = pane }
    }
    func toggleMaximize(_ pane: FolmiPane? = nil) {
        guard snapshot != nil else { return }
        paneLayout.toggleMaximize(pane ?? paneLayout.focused)
    }
    /// Collapsing the terminal hides it but keeps its shell running, like Control+`.
    func closePane(_ pane: FolmiPane? = nil) {
        let target = pane ?? paneLayout.focused
        if target == .terminal { showTerminal = false } else { paneLayout.close(target) }
    }
    func commit() {
        guard canCommit, let repository, let state = snapshot else { return }
        if state.files.contains(where: \.hasStaged), commitCheck?.fingerprint != state.fingerprint {
            commitAfterCheck(state); return
        }
        let unreviewed = unreviewedStaged
        if let check = commitCheck, check.fingerprint == state.fingerprint, check.blocking || !unreviewed.isEmpty, commitCheckOverride != state.fingerprint {
            commitCheckOverride = state.fingerprint
            var list = check.findings.filter(\.blocking).prefix(4).map { "\($0.label)：\($0.path) \($0.detail)" }
            if !unreviewed.isEmpty {
                list.append("没验收：暂存区里有 \(unreviewed.values.reduce(0, +)) 处改动不是你收下的（\(unreviewed.keys.sorted().prefix(3).joined(separator: "、"))）。可能是 agent 或终端执行了 git add。")
            }
            errorMessage = "提交前检查发现问题，没有提交：\n\(list.joined(separator: "\n"))\n\n确认没问题的话，再按一次提交（⌘⏎）。"
            return
        }
        let message = draftMessage, amend = amendLast
        let title = amend ? "修订提交" : "提交"
        // Committing a merge that stopped on a conflict finishes the pull; ⌘Z then goes back to before the pull.
        let pullStart = state.operation == .merge && !amend ? pullStartHeads[state.root.path] : nil
        mutate(title, clearDraft: true) { [weak self] in
            let before = try await repository.currentHead(), branch = try await repository.currentBranchRef()
            let head = try await repository.commit(message: message, amend: amend, expectedFingerprint: state.fingerprint)
            let subject = message.components(separatedBy: "\n").first ?? ""
            await MainActor.run {
                if let pullStart {
                    self?.pullStartHeads[state.root.path] = nil
                    self?.pushUndo("拉取（合并 \(head.prefix(7))）", .reset(restore: pullStart.head, current: head, branch: pullStart.branch))
                } else {
                    self?.pushUndo("\(title) \(head.prefix(7)) \(subject.prefix(30))", .head(restore: before, current: head, branch: branch))
                }
                self?.lastCommit = CommitToast(id: head, subject: subject)
            }
            return head
        }
    }
    func setAmend(_ value: Bool) {
        guard !busy else { return }
        amendLast = value
        guard value, draftMessage.isEmpty, let repository, snapshot?.head != nil else { return }
        busy = true
        Task {
            do { draftMessage = try await repository.latestCommitMessage() }
            catch { report(error, title: "读取完整提交消息失败"); amendLast = false }
            busy = false
        }
    }
    func checkout(_ branch: String) {
        guard let repository, let state = snapshot, branch != state.branch else { return }
        if editorWorkspace?.hasUnsavedChanges == true { report(FolmiFailure(message: "先保存或关闭当前项目中未保存的编辑，再切换分支。"), title: "仍有编辑草稿"); return }
        mutate("切换分支") { try await repository.checkout(branch: branch, expectedFingerprint: state.fingerprint); return branch }
    }
    /// `after` runs once the status is read again, whether or not the operation succeeded.
    /// `succeeded` runs only when the operation went through, before the reload: review marks and counts wait for
    /// it, so a failed stage or discard is not counted as done.
    func mutate(_ title: String, clearDraft: Bool = false, operation: @escaping () async throws -> String,
                succeeded: (() -> Void)? = nil, after: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true; diffRequest = UUID(); deliveryPlan = nil
        Task {
            do {
                let output = try await operation()
                succeeded?()
                record(title, output.isEmpty ? "操作已完成。" : output)
                if clearDraft { draftMessage = ""; autoDraft = nil; amendLast = false; commitSuggestion = .idle; suggestionKey = nil }
                try savePreferencesNow()
            } catch { report(error, title: title + "失败") }
            do { try await reload() } catch { report(error, title: "操作后刷新失败") }
            after?()
            busy = false
        }
    }
    /// Autosaves are written here one after another; a save made now waits behind them, so an older autosave can
    /// never land after a newer state.
    static let preferenceWrites = DispatchQueue(label: "Folmi.preferences", qos: .utility)
    func record(_ title: String, _ details: String, isError: Bool = false) {
        activity.insert(ActivityEntry(title: title, details: details, isError: isError, projectPath: repositoryURL?.path), at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
    }
    func report(_ error: Error, title: String) {
        errorMessage = error.localizedDescription; record(title, error.localizedDescription, isError: true)
        PerfLog.note("error", "\(title): \(error.localizedDescription)")
    }
}
