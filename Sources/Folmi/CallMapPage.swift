import AppKit
import FolmiCore
import SwiftUI

/// 调用关系: one function at the center, who calls it and what it calls, as two trees or a graph. Read from the
/// files on disk in the background; nothing is stored apart from an in-memory cache.
@MainActor
@Observable
final class CallMapState {
    enum Mode: String, CaseIterable { case tree = "上下游", graph = "关系图" }
    var root: String?
    var graph: CallGraph?
    @ObservationIgnored var cache = CallGraphCache()
    var building = false
    /// The status fingerprint the graph was read at; a change (an agent edited files) reads it again.
    @ObservationIgnored var builtAt: String?
    var problem: String?
    var focus: CodeSymbol?
    /// Centers visited before this one, for ⌫ / 后退.
    var trail: [CodeSymbol] = []
    var mode: Mode = .tree
    var query = ""
    var expanded: Set<String> = []
    @ObservationIgnored var contentBefore: FolmiContent = .editor
    @ObservationIgnored var buildTask: Task<Void, Never>?
    /// Functions each diff removed and who still calls them, keyed by the diff and the graph it was read from.
    var removed: [String: [RemovedCallImpact]] = [:]
    /// Functions each diff gave new parameters, with every call checked; keyed like `removed`.
    var signatures: [String: [SignatureImpact]] = [:]
}

extension FolmiModel {
    static let callMapExtensions: Set<String> = ["js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "vue", "svelte", "py", "pyi"]

    /// ⌃⌥H / 查看调用关系: the function under the cursor in the editor, or the page as it was.
    func showCallsAtCursor() {
        guard let editor = editorWorkspace, let document = editor.selectedDocument, content == .editor else { showCallMap(); return }
        let state = editor.tabStates[document.id]
        showCalls(path: document.path, text: document.text, location: state?.selectionLocation ?? 0)
    }

    /// The function at `location` in `path` (the editor's text), centered on the 调用关系 page.
    func showCalls(path: String, text: String, location: Int) {
        guard Self.callMapExtensions.contains((path as NSString).pathExtension.lowercased()) else {
            editorWorkspace?.showNotice("调用关系目前支持 JS、TS 和 Python 文件")
            return
        }
        let (word, line) = Self.word(in: text, at: location)
        showCallMap()
        Task {
            await ensureCallGraph()
            guard let graph = callMap.graph else { return }
            if let symbol = graph.symbol(path: path, line: line, word: word) ?? graph.moduleSymbol(path: path) {
                focusCall(symbol)
            } else {
                callMap.problem = "没在 \((path as NSString).lastPathComponent) 第 \(line) 行认出函数。"
            }
        }
    }

    func showCallMap() {
        if content != .calls { callMap.contentBefore = content }
        content = .calls
        Task { await ensureCallGraph() }
    }

    func leaveCallMap() { showContent(callMap.contentBefore == .calls ? .editor : callMap.contentBefore) }

    /// The identifier around `location` and its 1-based line.
    static func word(in text: String, at location: Int) -> (String?, Int) {
        let source = text as NSString
        let at = min(max(location, 0), source.length)
        let line = source.substring(to: at).reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
        func isPart(_ index: Int) -> Bool {
            guard index >= 0, index < source.length, let scalar = UnicodeScalar(source.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
        }
        var start = at, end = at
        while isPart(start - 1) { start -= 1 }
        while isPart(end) { end += 1 }
        return (end > start ? source.substring(with: NSRange(location: start, length: end - start)) : nil, line)
    }

    /// Reads the project again when it changed since the last read; unchanged files come from the cache.
    func ensureCallGraph(force: Bool = false) async {
        guard let repository, let root = repositoryURL else { return }
        let key = (snapshot?.fingerprint ?? "") + (snapshot?.head ?? "")
        if callMap.root != root.path {
            callMap.buildTask?.cancel()
            callMap.root = root.path; callMap.graph = nil; callMap.cache = CallGraphCache(); callMap.builtAt = nil
            callMap.focus = nil; callMap.trail = []; callMap.expanded = []; callMap.problem = nil
        }
        if !force, callMap.graph != nil, callMap.builtAt == key { return }
        if let running = callMap.buildTask { await running.value; if callMap.builtAt == key, !force { return } }
        callMap.building = true
        let cache = callMap.cache
        let task = Task { [weak self] in
            let files: [String]
            do { files = try await repository.callMapFiles() } catch {
                self?.callMap.problem = error.localizedDescription; self?.callMap.building = false; return
            }
            let (graph, saved) = await Task.detached(priority: .userInitiated) { CallGraph.build(root: root, files: files, cache: cache) }.value
            guard let self, self.repositoryURL == root else { return }
            self.callMap.graph = graph; self.callMap.cache = saved; self.callMap.builtAt = key; self.callMap.building = false
            // The center may have moved lines or gone; keep it by name.
            if let focus = self.callMap.focus, graph.index(of: focus) == nil {
                self.callMap.focus = graph.symbols.first { $0.path == focus.path && $0.qualifiedName == focus.qualifiedName }
            }
        }
        callMap.buildTask = task
        await task.value
        if callMap.buildTask == task { callMap.buildTask = nil }
    }

    /// 影响 on a file in 逐个验收: the functions its diff changes, and how many places call each. Nil when the call
    /// map cannot say: not JS / TS / Python, not read yet, or a staged diff whose lines may not match the file on disk.
    func callImpacts(for diff: FileDiff) -> [CallImpact]? {
        guard Self.callMapApplies(diff), !Self.removesFile(diff),
              let graph = callMap.graph, callMap.root == repositoryURL?.path else { return nil }
        var lines: [Int] = [], gaps: [Int] = []
        for hunk in diff.hunks {
            let changed = hunk.changedNewLines
            lines += changed.lines; gaps += changed.gaps
        }
        return graph.changedSymbols(path: diff.file.path, lines: lines, gaps: gaps).map(graph.impact)
    }

    /// A JS / TS / Python diff whose new side is the file on disk the call map reads: a staged diff with more
    /// changes in the work tree is not.
    static func callMapApplies(_ diff: FileDiff) -> Bool {
        callMapExtensions.contains(((diff.file.originalPath ?? diff.file.path) as NSString).pathExtension.lowercased())
            && !(diff.area == .staged && diff.file.hasWorking)
    }

    static func removesFile(_ diff: FileDiff) -> Bool {
        diff.area == .working ? diff.file.worktreeCode == "D" : diff.file.indexCode == "D"
    }

    private func removedKey(_ diff: FileDiff) -> String { diff.allChangesKey + "|" + diff.fingerprint + "|" + (callMap.builtAt ?? "") }

    /// Functions the diff deleted or renamed, with the places that still call the old name.
    func removedCallImpacts(for diff: FileDiff) -> [RemovedCallImpact] { callMap.removed[removedKey(diff)] ?? [] }

    /// Functions whose parameters the diff changed, and whether their calls still fit.
    func signatureImpacts(for diff: FileDiff) -> [SignatureImpact] { callMap.signatures[removedKey(diff)] ?? [] }

    /// Reads the call map for 逐个验收 when it shows JS / TS / Python changes; not in 大仓库模式, where reading every
    /// file again after each change costs too much (the 调用关系 page still reads it when opened). Then, for diffs
    /// that remove lines, the file before the change is read and linked in its place to find calls to names it lost.
    func prepareCallImpacts(_ diffs: [FileDiff]) async {
        let wanted = diffs.filter(Self.callMapApplies)
        guard !largeRepositoryOn, !wanted.isEmpty, let repository else { return }
        await ensureCallGraph()
        guard let graph = callMap.graph, let root = repositoryURL else { return }
        var found: [String: [RemovedCallImpact]] = [:]
        var signatures: [String: [SignatureImpact]] = [:]
        // Each file links the whole project once more (about half a second on a thousand files): the first 20 only.
        for diff in wanted.prefix(20) {
            let key = removedKey(diff)
            if let known = callMap.removed[key] { found[key] = known; signatures[key] = callMap.signatures[key]; continue }
            guard let old = diff.versions?.old,
                  Self.removesFile(diff) || diff.hunks.contains(where: { $0.lines.contains { $0.kind == .deletion } }) else { continue }
            guard let data = try? await repository.bytes(of: old, limit: 1_000_000) else { continue }
            let path = Self.removesFile(diff) ? nil : diff.file.path, oldPath = diff.file.originalPath ?? diff.file.path
            let (removed, changed) = await Task.detached(priority: .utility) {
                (graph.removedImpacts(path: path, oldPath: oldPath, oldData: data),
                 path.map { graph.signatureImpacts(path: $0, oldData: data, oldPath: oldPath) } ?? [])
            }.value
            found[key] = removed; signatures[key] = changed
            guard repositoryURL == root else { return }
        }
        callMap.removed = found
        callMap.signatures = signatures
    }

    /// 影响 → the 调用关系 page centered on that function.
    func showCallMap(for symbol: CodeSymbol) {
        showCallMap()
        focusCall(symbol)
    }

    func focusCall(_ symbol: CodeSymbol) {
        if let current = callMap.focus, current != symbol { callMap.trail.append(current) }
        callMap.focus = symbol
        callMap.query = ""; callMap.problem = nil; callMap.expanded = []
    }

    func callMapBack() {
        guard let previous = callMap.trail.popLast() else { return }
        callMap.focus = previous; callMap.expanded = []
    }

    /// Opens `path` at `line` in the editor.
    func openCallSite(_ path: String, line: Int) {
        guard let editor = editorWorkspace else { return }
        do {
            try editor.reveal(path: path, line: line, column: 1)
            content = .editor
            focusPane(.editor)
        } catch { report(error, title: "打开文件失败") }
    }
}

struct CallMapPage: View {
    let model: FolmiModel
    @Environment(\.folmiTheme) private var theme
    @FocusState private var searching: Bool

    var body: some View {
        let _ = PerfLog.body("CallMapPage")
        let state = model.callMap
        VStack(spacing: 0) {
            header(state)
            if let problem = state.problem {
                Text(problem).themedFont(.caption, points: 10).foregroundStyle(ThemeColor(token: .modified))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 6)
            }
            Divider()
            Group {
                if let graph = state.graph {
                    if !state.query.isEmpty { results(graph.search(state.query)) }
                    else if graph.isEmpty { panePlaceholder(symbol: "point.3.connected.trianglepath.dotted", title: "没有可以分析的文件",
                                                            detail: "调用关系目前读 JS、TS 和 Python 文件，这个项目里没有。") }
                    else if let focus = state.focus {
                        switch state.mode {
                        case .tree: CallTreeView(model: model, graph: graph, focus: focus)
                        case .graph: CallGraphView(model: model, graph: graph, focus: focus)
                        }
                    } else { start(graph) }
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在读项目里的 JS、TS 和 Python 文件…").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.theme(theme, \.card))
        .task(id: model.snapshot?.fingerprint) { await model.ensureCallGraph() }
        .onKeyPress(.delete) {
            guard !searching, !state.trail.isEmpty else { return .ignored }
            model.callMapBack(); return .handled
        }
    }

    private func header(_ state: CallMapState) -> some View {
        HStack(spacing: 8) {
            Button { model.callMapBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(state.trail.isEmpty).help("回到上一个函数（⌫）")
            if let focus = state.focus {
                Image(systemName: CallSymbolIcon.name(focus.kind)).foregroundStyle(.secondary)
                Text(focus.qualifiedName).themedFont(.body.weight(.semibold), points: 13).lineLimit(1).truncationMode(.middle)
                Button("\(focus.fileName):\(focus.line)") { model.openCallSite(focus.path, line: focus.line) }
                    .buttonStyle(.link).themedFont(.caption, points: 10).help("打开 \(focus.path) 第 \(focus.line) 行")
            } else {
                Text("调用关系").themedFont(.body.weight(.semibold), points: 13)
            }
            Spacer(minLength: 8)
            TextField("搜索函数名", text: Binding(get: { state.query }, set: { state.query = $0 }))
                .textFieldStyle(.roundedBorder).frame(width: 180).focused($searching)
                .onSubmit { if let first = state.graph?.search(state.query).first { model.focusCall(first) } }
            Picker("", selection: Binding(get: { state.mode }, set: { state.mode = $0 })) {
                ForEach(CallMapState.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            if state.building { ProgressView().controlSize(.small) }
            else {
                Button { Task { await model.ensureCallGraph(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("重新读一遍项目")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottomLeading) {
            if let graph = state.graph {
                Text("读了 \(graph.fileCount) 个文件\(graph.skippedFiles > 0 ? "，跳过 \(graph.skippedFiles) 个压缩或超大的" : "") · 按磁盘上的文件算，没保存的不算 · 灰字「可能」是只按方法名对上的")
                    .themedFont(.caption2, points: 9).foregroundStyle(.tertiary).lineLimit(1)
                    .padding(.leading, 12).offset(y: 12)
            }
        }
        .padding(.bottom, state.graph == nil ? 0 : 12)
    }

    private func results(_ found: [CodeSymbol]) -> some View {
        List {
            if found.isEmpty { Text("没有叫这个名字的函数。").foregroundStyle(.secondary) }
            ForEach(found) { symbol in
                Button { model.focusCall(symbol) } label: { CallSymbolLabel(symbol: symbol, detail: "\(symbol.path):\(symbol.line)") }
                    .buttonStyle(.plain)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
    }

    /// Before any center: how to pick one, and the functions called from the most places.
    private func start(_ graph: CallGraph) -> some View {
        let busiest = graph.mostCalled(limit: 12)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("把光标放在 JS、TS 或 Python 的函数名上，按 ⌃⌥H 或右键「查看调用关系」；也可以在右上角搜函数名。")
                    .themedFont(.callout, points: 12).foregroundStyle(.secondary)
                if !busiest.isEmpty {
                    Text("被调用最多的").themedFont(.caption.weight(.semibold), points: 10).foregroundStyle(.secondary)
                    ForEach(busiest, id: \.symbol.id) { symbol, count in
                        Button { model.focusCall(symbol) } label: {
                            CallSymbolLabel(symbol: symbol, detail: "\(count) 个函数调用 · \(symbol.path)")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 影响 under a file's header in 逐个验收: each changed function and how many places call it.
struct CallImpactRow: View {
    let model: FolmiModel
    let impacts: [CallImpact]
    var removed: [RemovedCallImpact] = []
    var signatures: [SignatureImpact] = []
    @State private var openRemoved: String?
    private static let shown = 4

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 10)).foregroundStyle(.secondary)
            Text("影响").themedFont(.caption.weight(.medium), points: 10).foregroundStyle(.secondary)
            // A name callers still use but that is gone comes first: it is the one that breaks.
            ForEach(removed.sorted { $0.sites.count > $1.sites.count }) { item in removedChip(item) }
            ForEach(signatures.sorted { $0.broken.count > $1.broken.count }) { item in signatureChip(item) }
            ForEach(impacts.prefix(Self.shown)) { impact in
                Button { model.showCallMap(for: impact.symbol) } label: {
                    (Text(impact.symbol.qualifiedName).font(.system(size: 11, design: .monospaced))
                     + Text(impact.sites == 0 ? " 没找到调用方" : " 被 \(impact.sites) 处调用")
                     + Text(impact.uncertainSites > 0 ? "（\(impact.uncertainSites) 处可能）" : "").foregroundColor(.secondary))
                        .themedFont(.caption, points: 10).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .themedCapsule(ThemeColor(token: impact.sites > 0 ? .modified : .selectedFill, opacity: impact.sites > 0 ? 0.14 : 1))
                }
                .buttonStyle(.plain)
                .help(help(impact))
            }
            if impacts.count > Self.shown {
                Text("等 \(impacts.count) 个函数").themedFont(.caption, points: 10).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("影响")
    }

    private func removedChip(_ item: RemovedCallImpact) -> some View {
        let old = item.symbol.qualifiedName
        let what = item.renamedTo.map { "\(old) 改名为 \($0)" } ?? "删了 \(old)"
        let broken = !item.sites.isEmpty
        let uncertain = item.sites.filter { !$0.certain }.count
        return Button { if broken { openRemoved = item.id } } label: {
            (Text(what).font(.system(size: 11, design: .monospaced))
             + Text(broken ? "，旧名字还有 \(item.sites.count) 处在调用" : (item.renamedTo == nil ? "，别处没有在调用" : "，旧名字别处没有在用"))
             + Text(uncertain > 0 ? "（\(uncertain) 处可能）" : "").foregroundColor(.secondary))
                .themedFont(.caption, points: 10).lineLimit(1)
                .foregroundStyle(broken ? AnyShapeStyle(ThemeColor(token: .removed)) : AnyShapeStyle(.primary))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .themedCapsule(ThemeColor(token: broken ? .removed : .selectedFill, opacity: broken ? 0.14 : 1))
        }
        .buttonStyle(.plain)
        .help(broken ? "这些地方还按旧名字调用 \(old)，改动之后会找不到它。点开看是哪几处。" : "改动前文件里有 \(old)，现在没有了；别的文件里没找到按这个名字调用它的地方。")
        .popover(isPresented: Binding(get: { openRemoved == item.id }, set: { if !$0 { openRemoved = nil } })) {
            RemovedCallSites(model: model, item: item) { openRemoved = nil }
        }
    }

    private func signatureChip(_ item: SignatureImpact) -> some View {
        let broken = item.broken.count
        let outcome: String
        if broken > 0 { outcome = "，\(broken) 处调用没跟着改" }
        else if item.sites.isEmpty { outcome = item.unknown > 0 ? "" : "，没找到调用" }
        else { outcome = item.sites.count == 1 ? "，调用对得上" : "，\(item.sites.count) 处调用都对得上" }
        let unknown = item.unknown > 0 ? "（\(item.unknown) 处展开传参，看不出）" : ""
        return Button { if !item.sites.isEmpty { openRemoved = item.id } } label: {
            (Text(item.symbol.qualifiedName).font(.system(size: 11, design: .monospaced))
             + Text(" 参数 ") + Text(item.before + " → " + item.after).font(.system(size: 11, design: .monospaced))
             + Text(outcome) + Text(unknown).foregroundColor(.secondary))
                .themedFont(.caption, points: 10).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(broken > 0 ? AnyShapeStyle(ThemeColor(token: .removed)) : AnyShapeStyle(.primary))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .themedCapsule(ThemeColor(token: broken > 0 ? .removed : .selectedFill, opacity: broken > 0 ? 0.14 : 1))
        }
        .buttonStyle(.plain)
        .help(broken > 0 ? "参数改了，有 \(broken) 处调用还按原来的参数传。点开看是哪几处、差在哪。"
              : "参数改了；按现在的参数检查了每一处调用，都对得上。只看参数个数和关键字名，不看类型。")
        .popover(isPresented: Binding(get: { openRemoved == item.id }, set: { if !$0 { openRemoved = nil } })) {
            SignatureCallSites(model: model, item: item) { openRemoved = nil }
        }
    }

    private func help(_ impact: CallImpact) -> String {
        guard !impact.callers.isEmpty else { return "这处改了 \(impact.symbol.qualifiedName)，没找到调用它的地方（不代表没人用）。点开看调用关系。" }
        let names = impact.callers.prefix(8).joined(separator: "、") + (impact.callers.count > 8 ? " 等" : "")
        return "这处改了 \(impact.symbol.qualifiedName)，\(impact.callers.count) 个函数调用它：\(names)。点开看调用关系。"
    }
}

/// The calls to a removed name, each one click from its line.
private struct RemovedCallSites: View {
    let model: FolmiModel
    let item: RemovedCallImpact
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.renamedTo.map { "还在用旧名字 \(item.symbol.qualifiedName) 的地方（新名字是 \($0)）" } ?? "还在调用 \(item.symbol.qualifiedName) 的地方")
                .themedFont(.callout.weight(.semibold), points: 12)
            Text("按改动前的文件算出来的：这些调用现在找不到它了。").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(item.sites) { site in
                        Button {
                            close()
                            model.openCallSite(site.path, line: site.line)
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(site.path):\(site.line)").font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Text(site.caller).themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(1)
                                if !site.certain { Text("可能").themedFont(.caption2, points: 9).foregroundStyle(.tertiary) }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("打开 \(site.path) 第 \(site.line) 行")
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(14).frame(width: 420)
    }
}

/// Every call to a function whose parameters changed: the ones that no longer fit first, with why.
private struct SignatureCallSites: View {
    let model: FolmiModel
    let item: SignatureImpact
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(item.symbol.qualifiedName) 的调用").themedFont(.callout.weight(.semibold), points: 12)
            Text("参数从 \(item.before) 改成了 \(item.after)。只按参数个数和关键字名检查，不看类型。")
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(item.sites) { site in
                        Button {
                            close()
                            model.openCallSite(site.path, line: site.line)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: site.problem == nil ? "checkmark" : "xmark").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(site.problem == nil ? ThemeColor(token: .added) : ThemeColor(token: .removed)).frame(width: 12)
                                Text("\(site.path):\(site.line)").font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Text(site.problem ?? site.caller).themedFont(.caption, points: 10)
                                    .foregroundStyle(site.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(ThemeColor(token: .removed))).lineLimit(1)
                                if !site.certain { Text("可能").themedFont(.caption2, points: 9).foregroundStyle(.tertiary) }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(site.caller) · 打开 \(site.path) 第 \(site.line) 行")
                    }
                    if item.unknown > 0 {
                        Text("另有 \(item.unknown) 处用展开传参（...args、*args），看不出个数。").themedFont(.caption, points: 10).foregroundStyle(.tertiary).padding(.top, 4)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(14).frame(width: 460)
    }
}

enum CallSymbolIcon {
    static func name(_ kind: CodeSymbol.Kind?) -> String {
        switch kind {
        case .function?: return "function"
        case .method?: return "m.square"
        case .class?: return "c.square"
        case .module?: return "doc.text"
        case nil: return "shippingbox"
        }
    }
}

struct CallSymbolLabel: View {
    let symbol: CodeSymbol
    let detail: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: CallSymbolIcon.name(symbol.kind)).foregroundStyle(.secondary).frame(width: 16)
            Text(symbol.kind == .module ? "\(symbol.name) 顶层" : symbol.qualifiedName).themedFont(.callout, points: 12).lineLimit(1)
            Text(detail).themedFont(.caption, points: 10).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 上下游

private enum CallDirection { case up, down }

/// Two trees side by side: who calls the center (expanding to their callers), and what it calls.
private struct CallTreeView: View {
    let model: FolmiModel
    let graph: CallGraph
    let focus: CodeSymbol

    var body: some View {
        let up = graph.callers(of: focus), down = graph.callees(of: focus)
        HStack(spacing: 0) {
            column(up.isEmpty ? "没找到调用它的地方" : "谁调用它（\(up.count)）", links: up, direction: .up,
                   empty: "没找到，不代表没人用：动态调用、框架按名字调用（路由、事件）认不出来。")
            Divider()
            column(down.isEmpty ? "它没有调用别的函数" : "它调用了谁（\(down.count)）", links: down, direction: .down,
                   empty: "只列项目里的函数和外部包，console、print 这类内置的不列。")
        }
    }

    private func column(_ title: String, links: [CallLink], direction: CallDirection, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).themedFont(.caption.weight(.semibold), points: 10).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if links.isEmpty { Text(empty).themedFont(.caption, points: 10).foregroundStyle(.tertiary).padding(12) }
                    ForEach(links) { link in
                        CallTreeRow(model: model, graph: graph, link: link, direction: direction, depth: 0,
                                    ancestors: [focus.id], key: link.id)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct CallTreeRow: View {
    let model: FolmiModel
    let graph: CallGraph
    let link: CallLink
    let direction: CallDirection
    let depth: Int
    let ancestors: Set<String>
    let key: String
    @State private var hovering = false

    var body: some View {
        let expanded = model.callMap.expanded.contains(key)
        let cycle = link.symbol.map { ancestors.contains($0.id) } ?? false
        let expandable = link.symbol != nil && !cycle && depth < 8
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Button {
                    if expanded { model.callMap.expanded.remove(key) } else { model.callMap.expanded.insert(key) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        .frame(width: 12).opacity(expandable ? 1 : 0)
                }
                .buttonStyle(.plain).disabled(!expandable)
                Image(systemName: CallSymbolIcon.name(link.symbol?.kind)).foregroundStyle(.secondary).frame(width: 16)
                Button { if let symbol = link.symbol { model.focusCall(symbol) } } label: {
                    Text(title).themedFont(.callout, points: 12).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(link.certain && link.symbol != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain).disabled(link.symbol == nil)
                .help(link.symbol == nil ? "外部包里的函数" : "以它为中心展开")
                ForEach(tags, id: \.self) { tag in
                    Text(tag).themedFont(.caption2, points: 9).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1).themedCapsule(ThemeColor(token: .selectedFill))
                }
                if cycle { Text("↺ 递归").themedFont(.caption2, points: 9).foregroundStyle(.tertiary) }
                Spacer(minLength: 6)
                Button(location.label) { model.openCallSite(location.path, line: location.line) }
                    .buttonStyle(.link).themedFont(.caption, points: 10).lineLimit(1)
                    .help(direction == .up ? "打开调用的那一行" : (link.symbol == nil ? "打开调用的那一行" : "打开它的定义"))
            }
            .padding(.leading, 10 + CGFloat(depth) * 16).padding(.trailing, 10).padding(.vertical, 3)
            .background(hovering ? ThemeColor(token: .hover) : ThemeColor(token: .hover, opacity: 0))
            .onHover { hovering = $0 }
            if expanded, let symbol = link.symbol {
                let children = direction == .up ? graph.callers(of: symbol) : graph.callees(of: symbol)
                if children.isEmpty {
                    Text(direction == .up ? "没找到调用它的地方" : "没有再调用别的")
                        .themedFont(.caption, points: 10).foregroundStyle(.tertiary).padding(.leading, 44 + CGFloat(depth) * 16).padding(.vertical, 2)
                }
                ForEach(children) { child in
                    CallTreeRow(model: model, graph: graph, link: child, direction: direction, depth: depth + 1,
                                ancestors: ancestors.union([symbol.id]), key: key + ">" + child.id)
                }
            }
        }
    }

    private var title: String {
        guard let symbol = link.symbol else { return link.external ?? "" }
        return symbol.kind == .module ? "\(symbol.name) 顶层" : symbol.qualifiedName
    }

    private var tags: [String] {
        var tags: [String] = []
        if link.kinds.contains(.render) { tags.append("渲染") }
        if link.kinds.contains(.reference) && !link.kinds.contains(.call) { tags.append("传入") }
        if !link.certain { tags.append("可能") }
        if link.symbol == nil { tags.append("外部") }
        return tags
    }

    private var location: (label: String, path: String, line: Int) {
        let site = (link.sitePath, link.siteLines.first ?? 1)
        let target: (String, Int) = direction == .down && link.symbol != nil ? (link.symbol!.path, link.symbol!.line) : site
        let name = (target.0 as NSString).lastPathComponent
        let extra = direction == .up && link.siteLines.count > 1 ? " 等 \(link.siteLines.count) 处" : ""
        return ("\(name):\(target.1)\(extra)", target.0, target.1)
    }
}

// MARK: - 关系图

/// Where the 关系图 is panned and how far it is zoomed. A drag on the empty background pans (`GraphPanSurface`);
/// the wheel, two-finger swipes and pinches reach the view under the pointer (often a box), so a local monitor
/// takes them while the pointer is over the graph.
@MainActor @Observable
final class CallGraphViewport {
    static let scales: ClosedRange<CGFloat> = 0.3...2
    var offset: CGSize = .zero
    var scale: CGFloat = 1
    @ObservationIgnored var hovering = false
    @ObservationIgnored private var monitor: Any?

    func clamp(_ scale: CGFloat) -> CGFloat { min(max(scale, Self.scales.lowerBound), Self.scales.upperBound) }
    func zoom(by factor: CGFloat) { scale = clamp(scale * factor) }
    /// Back to the center, at 100% or smaller when the graph would not fit.
    func reset(fitting content: CGSize, in view: CGSize) {
        offset = .zero
        guard content.width > 0, content.height > 0 else { scale = 1; return }
        scale = clamp(min(1, view.width / content.width, view.height / content.height))
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Two-finger swipes and the wheel pan; with ⌘ held they zoom, as a pinch does. Returns whether the event was used.
    func handle(_ event: NSEvent) -> Bool {
        guard hovering else { return false }
        if event.type == .magnify { zoom(by: 1 + event.magnification); return true }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        if event.modifierFlags.contains(.command) {
            zoom(by: exp(event.scrollingDeltaY * step * 0.01))
        } else {
            offset.width += event.scrollingDeltaX * step
            offset.height += event.scrollingDeltaY * step
        }
        return true
    }
}

/// The empty background of the 关系图: pressing and dragging on it moves the graph. AppKit rather than a SwiftUI
/// drag gesture, so the boxes above keep their clicks and the drag follows the mouse exactly.
private struct GraphPanSurface: NSViewRepresentable {
    let pan: (CGSize) -> Void
    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }
    func updateNSView(_ view: SurfaceView, context: Context) { view.pan = pan }

    final class SurfaceView: NSView {
        var pan: ((CGSize) -> Void)?
        private var last: NSPoint?
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        // A drag in a window that is not in front moves the graph too, as it does in maps and canvases.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { last = event.locationInWindow; NSCursor.closedHand.push() }
        override func mouseDragged(with event: NSEvent) {
            guard let last else { return }
            let point = event.locationInWindow
            // Window coordinates grow upward; SwiftUI offsets grow downward.
            pan?(CGSize(width: point.x - last.x, height: last.y - point.y))
            self.last = point
        }
        override func mouseUp(with event: NSEvent) { if last != nil { NSCursor.pop() }; last = nil }
    }
}

/// The center with two levels of callers on the left and two of callees on the right. Click a box to center it;
/// drag (or swipe) to move around, ⌘-scroll or pinch to zoom.
private struct CallGraphView: View {
    let model: FolmiModel
    let graph: CallGraph
    let focus: CodeSymbol
    @Environment(\.folmiTheme) private var theme
    @State private var viewport = CallGraphViewport()
    /// The graph can be moved now, so a column holds far more than fits on screen.
    private static let perColumn = 40
    private static let boxWidth: CGFloat = 180
    private static let columnStep: CGFloat = 230
    private static let rowStep: CGFloat = 48

    private struct Node: Identifiable {
        let id: String
        let symbol: CodeSymbol?
        let title: String
        let detail: String
        let certain: Bool
        let column: Int
        var row = 0
    }

    private struct Layout {
        var nodes: [Node] = []
        var edges: [(String, String)] = []
        var hidden: [Int: Int] = [:]
    }

    private func layout() -> Layout {
        var result = Layout()
        func node(_ link: CallLink, column: Int) -> Node {
            // The name first; a narrow box cuts the class off the front otherwise.
            let title = link.symbol.map { $0.kind == .module ? "\($0.name) 顶层" : $0.name } ?? (link.external ?? "")
            return Node(id: link.symbol?.id ?? "ext:" + (link.external ?? ""), symbol: link.symbol, title: title,
                        detail: link.symbol.map(Self.detail) ?? "外部", certain: link.certain, column: column)
        }
        var placed: [Int: [Node]] = [:]
        var known: Set<String> = [focus.id]
        func add(_ node: Node, from: String, toward center: Bool) {
            result.edges.append(center ? (node.id, from) : (from, node.id))
            guard known.insert(node.id).inserted else { return }
            if placed[node.column, default: []].count >= Self.perColumn { result.hidden[node.column, default: 0] += 1; return }
            placed[node.column, default: []].append(node)
        }
        placed[2] = [Node(id: focus.id, symbol: focus, title: focus.name, detail: Self.detail(focus), certain: true, column: 2)]
        let up = graph.callers(of: focus), down = graph.callees(of: focus)
        for link in up { add(node(link, column: 1), from: focus.id, toward: true) }
        for link in down { add(node(link, column: 3), from: focus.id, toward: false) }
        for parent in placed[1] ?? [] {
            guard let symbol = parent.symbol else { continue }
            for link in graph.callers(of: symbol).prefix(6) { add(node(link, column: 0), from: parent.id, toward: true) }
        }
        for parent in placed[3] ?? [] {
            guard let symbol = parent.symbol else { continue }
            for link in graph.callees(of: symbol).prefix(6) { add(node(link, column: 4), from: parent.id, toward: false) }
        }
        for column in 0...4 {
            for (row, var node) in (placed[column] ?? []).enumerated() { node.row = row; result.nodes.append(node) }
        }
        let shown = Set(result.nodes.map(\.id))
        result.edges = result.edges.filter { shown.contains($0.0) && shown.contains($0.1) }
        return result
    }

    /// The whole graph at 100%: five columns, as tall as the fullest one (plus its 还有 n 个 line).
    private static func contentSize(_ layout: Layout) -> CGSize {
        let rows = Dictionary(grouping: layout.nodes, by: \.column).values.map(\.count).max() ?? 1
        return CGSize(width: columnStep * 5, height: CGFloat(rows) * rowStep + (layout.hidden.isEmpty ? 0 : 28) + 24)
    }

    var body: some View {
        let layout = layout()
        let content = Self.contentSize(layout)
        let counts = Dictionary(grouping: layout.nodes, by: \.column).mapValues(\.count)
        let tallest = CGFloat(counts.values.max() ?? 1)
        let points = Dictionary(uniqueKeysWithValues: layout.nodes.map { node in
            (node.id, position(node, count: counts[node.column] ?? 1, tallest: tallest))
        })
        GeometryReader { geometry in
            ZStack {
                GraphPanSurface { delta in viewport.offset.width += delta.width; viewport.offset.height += delta.height }
                graphContent(layout, points: points, content: content)
                    .frame(width: content.width, height: content.height)
                    .scaleEffect(viewport.scale)
                    .offset(viewport.offset)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onContinuousHover { phase in
                if case .active = phase { viewport.hovering = true } else { viewport.hovering = false }
            }
            .overlay(alignment: .bottomTrailing) { controls(content: content, view: geometry.size) }
            .onChange(of: focus.id, initial: true) { viewport.reset(fitting: content, in: geometry.size) }
        }
        .onAppear { viewport.start() }
        .onDisappear { viewport.stop() }
    }

    private func graphContent(_ layout: Layout, points: [String: CGPoint], content: CGSize) -> some View {
        // Only the boxes take clicks; the lines and empty space let a press through to the pan surface below.
        ZStack {
            Canvas { context, _ in
                let color = Color.theme(theme, \.tertiaryText)
                for (from, to) in layout.edges {
                    guard let a = points[from], let b = points[to] else { continue }
                    let start = CGPoint(x: a.x + Self.boxWidth / 2, y: a.y), end = CGPoint(x: b.x - Self.boxWidth / 2, y: b.y)
                    var path = Path()
                    path.move(to: start)
                    let middle = (start.x + end.x) / 2
                    path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
                    context.stroke(path, with: .color(color.opacity(0.6)), lineWidth: 1)
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: end.x - 5, y: end.y - 3)); arrow.addLine(to: end); arrow.addLine(to: CGPoint(x: end.x - 5, y: end.y + 3))
                    context.stroke(arrow, with: .color(color.opacity(0.8)), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
            ForEach(layout.nodes) { node in
                box(node).position(points[node.id] ?? .zero)
            }
            ForEach(layout.hidden.sorted(by: { $0.key < $1.key }), id: \.key) { column, count in
                Text("还有 \(count) 个，在「上下游」里看全").themedFont(.caption2, points: 9).foregroundStyle(.tertiary)
                    .position(x: columnX(column), y: content.height - 14).allowsHitTesting(false)
            }
            if layout.nodes.count == 1 {
                Text("没找到它的上下游。").themedFont(.caption, points: 10).foregroundStyle(.tertiary)
                    .position(x: content.width / 2, y: content.height / 2 + 40).allowsHitTesting(false)
            }
        }
    }

    private func controls(content: CGSize, view: CGSize) -> some View {
        HStack(spacing: 2) {
            Button { viewport.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus") }.help("缩小（⌘ 加滚轮也可以）")
            Text("\(Int((viewport.scale * 100).rounded()))%").themedFont(.caption2.monospacedDigit(), points: 9)
                .foregroundStyle(.secondary).frame(width: 38)
            Button { viewport.zoom(by: 1.25) } label: { Image(systemName: "plus") }.help("放大（⌘ 加滚轮也可以）")
            Button { viewport.reset(fitting: content, in: view) } label: { Image(systemName: "scope") }.help("回到中心")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(ThemeColor(token: .canvas)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeColor(token: .border), lineWidth: 1))
        .padding(10)
    }

    private static func detail(_ symbol: CodeSymbol) -> String {
        (symbol.container.map { $0 + " · " } ?? "") + "\(symbol.fileName):\(symbol.line)"
    }

    private func columnX(_ column: Int) -> CGFloat { Self.columnStep * (CGFloat(column) + 0.5) }

    /// Rows centered on the middle of the graph, so the center box sits level with its neighbours.
    private func position(_ node: Node, count: Int, tallest: CGFloat) -> CGPoint {
        let top = (tallest - CGFloat(count)) * Self.rowStep / 2
        return CGPoint(x: columnX(node.column), y: 12 + top + Self.rowStep * (CGFloat(node.row) + 0.5))
    }

    private func box(_ node: Node) -> some View {
        let center = node.id == focus.id
        return Button { if let symbol = node.symbol, !center { model.focusCall(symbol) } } label: {
            VStack(spacing: 1) {
                Text(node.title).themedFont(center ? .callout.weight(.semibold) : .caption, points: center ? 12 : 10)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(node.certain && node.symbol != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(node.certain ? node.detail : node.detail + " · 可能").themedFont(.caption2, points: 9).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 5).frame(width: Self.boxWidth)
            .background(RoundedRectangle(cornerRadius: 6).fill(center ? ThemeColor(token: .selectedFill) : ThemeColor(token: .canvas)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(center ? ThemeColor(token: .accent) : ThemeColor(token: .border), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(node.symbol.map { center ? $0.path : "以 \($0.qualifiedName) 为中心" } ?? "外部包里的函数")
    }
}
