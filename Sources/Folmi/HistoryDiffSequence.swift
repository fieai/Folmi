import FolmiCore
import SwiftUI

/// A history comparison keeps both object IDs fixed while its file diffs load.
struct HistoryDiffScope: Hashable, Sendable {
    let commit: String
    let base: String?

    init(commit: String, base: String?) {
        self.commit = commit
        self.base = base == commit ? nil : base
    }

    func diff(_ file: CommitFileChange, in repository: GitRepository) async throws -> FileDiff {
        if let base { return try await repository.compareDiff(base: base, target: commit, file: file) }
        return try await repository.commitDiff(commit, file: file)
    }
}

extension SideBySideFile {
    static func history(_ diff: FileDiff, sideTitles: (old: String, new: String), unified: Bool, columnWidth: CGFloat,
                        previewHeight: CGFloat = ChangePreview.defaultHeight, searchHit: DiffSearchHit? = nil,
                        onSearchAnchor: ((DiffSearchHit) -> Void)? = nil) -> Self {
        Self(diff: diff, selected: [], busy: false, columnWidth: columnWidth,
             onToggleLine: { _, _ in }, onApplyHunk: { _, _ in }, onApplySelection: { _, _ in },
             onStageFile: { _ in }, onUnstageFile: { _ in }, onEditFile: { _ in },
             comments: [], onComment: { _, _, _ in }, onDeleteComment: { _ in },
             showsHeader: false, allowsLineSelection: false, readOnly: true,
             sideTitles: sideTitles, unified: unified, previewHeight: previewHeight,
             searchHit: searchHit, onSearchAnchor: onSearchAnchor)
    }
}

@MainActor @Observable
private final class HistoryDiffFiles {
    enum Entry {
        case loaded(FileDiff)
        case failed(String)
    }

    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var requests: [String: Task<Void, Never>] = [:]

    func load(_ file: CommitFileChange, scope: HistoryDiffScope, repository: GitRepository) async {
        guard entries[file.path] == nil, !Task.isCancelled else { return }
        if let request = requests[file.path] {
            await request.value
            return
        }
        // A visible row and a search can ask for the same immutable diff.
        let request = Task { [weak self] in
            defer { self?.requests.removeValue(forKey: file.path) }
            guard !Task.isCancelled else { return }
            let entry: Entry
            do { entry = .loaded(try await scope.diff(file, in: repository)) }
            catch { entry = .failed(error.localizedDescription) }
            if !Task.isCancelled { self?.entries[file.path] = entry }
        }
        requests[file.path] = request
        await request.value
    }

    func diff(at path: String) -> FileDiff? {
        if case let .loaded(diff) = entries[path] { return diff }
        return nil
    }

    func cancel() {
        for request in requests.values { request.cancel() }
    }
}

struct HistoryDiffSequence: View {
    let repository: GitRepository
    let scope: HistoryDiffScope
    let files: [CommitFileChange]
    let selectedPath: String?
    let sideTitles: (old: String, new: String)
    let unified: Bool
    let columnWidth: CGFloat
    var initiallyFocused = true
    var searchRequestID = 0

    @State private var source = HistoryDiffFiles()
    @State private var folded: Set<String> = []
    @State private var searchOpen = false
    @State private var query = ""
    @State private var result: (query: String, matches: DiffSearch.Result)?
    @State private var matchIndex = 0
    @FocusState private var focused: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.folmiTheme) private var theme

    private var matches: DiffSearch.Result? { result?.query == query ? result?.matches : nil }
    private var activeHit: DiffSearchHit? {
        guard searchOpen, let hits = matches?.hits, hits.indices.contains(matchIndex) else { return nil }
        return hits[matchIndex]
    }
    private var searchRequest: String? { searchOpen && !query.isEmpty ? query : nil }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if searchOpen { searchBar; Divider() }
            diffs
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { if initiallyFocused { focused = true } }
        .onDisappear { source.cancel() }
        .onChange(of: searchRequestID) { _, _ in openSearch() }
        .onKeyPress("f", phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            openSearch()
            return .handled
        }
        .task(id: searchRequest) {
            guard let request = searchRequest else { return }
            await find(request)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Label("连续查看 · \(files.count) 个文件", systemImage: "doc.on.doc")
            Spacer()
            Button(folded.count == files.count ? "展开全部" : "折叠全部") {
                folded = folded.count == files.count ? [] : Set(files.map(\.path))
            }
            .controlSize(.small)
            PaneIconButton(symbol: "magnifyingglass", help: "查找历史差异（⌘F）", action: openSearch)
        }
        .themedFont(.caption, points: 11).padding(.horizontal, 10).padding(.vertical, 4)
    }

    private var diffs: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(files) { file in
                        Section {
                            if !folded.contains(file.path) { fileBody(file, proxy: proxy) }
                        } header: {
                            fileHeader(file).id(file.path)
                        }
                    }
                }
            }
            .onChange(of: selectedPath, initial: true) { _, path in
                guard let path else { return }
                reveal(path, proxy: proxy)
            }
            .onChange(of: activeHit) { _, hit in
                guard let hit, let path = files.first(where: { source.diff(at: $0.path)?.allChangesKey == hit.fileKey })?.path else { return }
                reveal(path, proxy: proxy)
            }
        }
    }

    private func reveal(_ path: String, proxy: ScrollViewProxy) {
        folded.remove(path)
        proxy.scrollTo(path, anchor: .top)
    }

    private func fileHeader(_ file: CommitFileChange) -> some View {
        let closed = folded.contains(file.path)
        return Button {
            if closed { folded.remove(file.path) }
            else { folded.insert(file.path) }
            focused = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: closed ? "chevron.right" : "chevron.down").font(.caption)
                Text(file.status).foregroundStyle(HistoryView.statusColor(file.status))
                Text(file.path).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .themedFont(.system(size: 12, weight: .medium, design: .monospaced), points: 12)
            .padding(.horizontal, 10).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.theme(theme, \.header))
        .overlay(alignment: .bottom) { Divider() }
        .help(closed ? "展开文件差异" : "折叠文件差异")
    }

    @ViewBuilder private func fileBody(_ file: CommitFileChange, proxy: ScrollViewProxy) -> some View {
        switch source.entries[file.path] {
        case let .loaded(diff):
            let hit = activeHit.flatMap { $0.fileKey == diff.allChangesKey ? $0 : nil }
            SideBySideFile.history(diff, sideTitles: sideTitles, unified: unified, columnWidth: columnWidth,
                                   searchHit: hit) { hit in
                // The row anchor appears only after its lazy file section has opened.
                DispatchQueue.main.async {
                    if activeHit == hit { proxy.scrollTo(hit, anchor: .center) }
                }
            }
        case let .failed(message):
            Label("读取差异失败。\(message)", systemImage: "exclamationmark.triangle")
                .themedFont(.caption, points: 11).foregroundStyle(.secondary).padding(12)
        case nil:
            ProgressView().controlSize(.small).padding(12)
                .accessibilityLabel("正在读取 \(file.path)")
                .task { await source.load(file, scope: scope, repository: repository) }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("在历史差异中查找…", text: $query)
                .themedTextField()
                .focused($searchFocused)
                .onAppear { searchFocused = true }
                .onSubmit { stepSearch(by: 1) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers == .shift else { return .ignored }
                    stepSearch(by: -1)
                    return .handled
                }
                .onExitCommand(perform: closeSearch)
                .accessibilityIdentifier("history-diff-search")
            if !query.isEmpty {
                if let matches {
                    let total = matches.hits.count
                    Text(total == 0 ? "没有匹配" : "\(matchIndex + 1) / \(total)" + (matches.limited ? "+" : ""))
                        .monospacedDigit().foregroundStyle(.secondary)
                    if source.entries.values.contains(where: { if case .failed = $0 { true } else { false } }) {
                        Image(systemName: "exclamationmark.triangle").help("部分文件读取失败，未计入查找")
                    }
                } else {
                    ProgressView().controlSize(.mini).accessibilityLabel("正在查找")
                }
            }
            PaneIconButton(symbol: "chevron.up", help: "上一项（⇧⏎）") { stepSearch(by: -1) }
                .disabled(matches?.hits.isEmpty != false)
            PaneIconButton(symbol: "chevron.down", help: "下一项（⏎）") { stepSearch(by: 1) }
                .disabled(matches?.hits.isEmpty != false)
            PaneIconButton(symbol: "xmark", help: "关闭查找（Esc）", action: closeSearch)
        }
        .themedFont(.caption, points: 11)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
    }

    private func openSearch() {
        searchOpen = true
        searchFocused = true
    }

    private func closeSearch() {
        searchOpen = false
        searchFocused = false
        focused = true
    }

    private func stepSearch(by offset: Int) {
        guard let count = matches?.hits.count, count > 0 else { return }
        matchIndex = (matchIndex + offset + count) % count
        searchFocused = true
    }

    private func find(_ request: String) async {
        do {
            try await Task.sleep(for: .milliseconds(120))
            for file in files {
                try Task.checkCancellation()
                await source.load(file, scope: scope, repository: repository)
            }
            try Task.checkCancellation()
            let diffs = files.compactMap { source.diff(at: $0.path) }
            let work = Task.detached(priority: .userInitiated) { try DiffSearch.find(request, in: diffs) }
            let matches = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, request == searchRequest else { return }
            matchIndex = 0
            result = (request, matches)
        } catch {
            // Closing the search or changing the query cancels the scan.
        }
    }
}
