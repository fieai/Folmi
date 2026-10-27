import AppKit
import FolmiCore
import SwiftUI

/// 接口: the back end's routes, each with the front-end requests that reach it, across the open project and its
/// 关联项目 (a front end and back end in separate repositories). Read from the files like the rest of 调用关系.
extension FolmiModel {
    var linkedProjects: [String] { repositoryURL.flatMap { savedProject($0.path) }?.linkedProjects ?? [] }

    /// Projects in the rail that can be linked: every other one that is still on disk.
    var linkableProjects: [ProjectPreferences] {
        projects.filter { $0.rootPath != repositoryURL?.path && !$0.isDemo && FileManager.default.fileExists(atPath: $0.rootPath) }
    }

    func setLinked(_ path: String, _ on: Bool) {
        guard let root = repositoryURL?.path else { return }
        func change(_ project: inout ProjectPreferences) {
            project.linkedProjects.removeAll { $0 == path }
            if on { project.linkedProjects.append(path) }
        }
        if let index = projects.firstIndex(where: { $0.rootPath == root }) { change(&projects[index]) }
        if let index = preferences.projects.firstIndex(where: { $0.rootPath == root }) { change(&preferences.projects[index]) }
        scheduleSave()
        if let graph = callMap.graph, let url = repositoryURL { Task { await refreshEndpoints(graph, root: url) } }
    }

    /// Pairs routes and requests in this project and the linked ones; linked projects are read in the background,
    /// each with its own cache.
    func refreshEndpoints(_ graph: CallGraph, root: URL) async {
        let linked = linkedProjects.map { path in (path, savedProject(path)?.name ?? (path as NSString).lastPathComponent) }
        let caches = callMap.linkedCaches
        let (map, saved) = await Task.detached(priority: .utility) { () -> (EndpointMap, [String: CallGraphCache]) in
            var sources: [(project: String?, graph: CallGraph)] = [(nil, graph)]
            var saved: [String: CallGraphCache] = [:]
            for (path, name) in linked {
                let url = URL(fileURLWithPath: path)
                guard let files = try? CallGraph.projectFiles(root: url) else { continue }
                let (other, cache) = CallGraph.build(root: url, files: files, cache: caches[path] ?? CallGraphCache())
                sources.append((name, other)); saved[path] = cache
            }
            return (EndpointMap.build(sources), saved)
        }.value
        guard repositoryURL == root else { return }
        callMap.endpoints = map
        callMap.linkedCaches = saved
    }

    /// 影响 on a back-end file: the endpoints whose handlers the diff changes.
    func endpointImpacts(for diff: FileDiff) -> [Endpoint] {
        guard Self.callMapApplies(diff), !Self.removesFile(diff), let map = callMap.endpoints, callMap.root == repositoryURL?.path else { return [] }
        var lines: [Int] = [], gaps: [Int] = []
        for hunk in diff.hunks { let changed = hunk.changedNewLines; lines += changed.lines; gaps += changed.gaps }
        return map.endpoints(changedIn: diff.file.path, lines: lines, gaps: gaps)
    }

    func showEndpoint(_ endpoint: Endpoint) {
        showCallMap()
        callMap.mode = .endpoints
        callMap.endpointFocus = endpoint.id
    }

    /// Opens a place in a linked project: that project first, then the file.
    func openEndpointPlace(project: String?, path: String, line: Int) {
        guard let project else { openCallSite(path, line: line); return }
        guard let root = linkedProjects.first(where: { (savedProject($0)?.name ?? ($0 as NSString).lastPathComponent) == project }) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(path))
    }
}

struct EndpointsView: View {
    let model: FolmiModel
    let map: EndpointMap
    let graph: CallGraph
    @State private var open: Set<String> = []
    @State private var unusedOnly = false

    var body: some View {
        let query = model.callMap.query.lowercased()
        let shown = map.endpoints
            .filter { query.isEmpty || $0.title.lowercased().contains(query) || ($0.handler?.name.lowercased().contains(query) ?? false) }
            .filter { !unusedOnly || map.uses(of: $0).isEmpty }
            .sorted { ($0.project ?? "", $0.path, $0.methodLabel) < ($1.project ?? "", $1.path, $1.methodLabel) }
        VStack(spacing: 0) {
            toolbar
            Divider()
            if map.isEmpty {
                panePlaceholder(symbol: "arrow.left.arrow.right", title: "没认出接口",
                                detail: "后端认 Express、Koa、NestJS、Next.js 路由文件、FastAPI、Flask 和 Django；前端认 fetch、axios 和项目自己包的 api.get('/x')。前后端在两个仓库时，点上面的「关联项目」。")
            } else {
                ScrollViewReader { proxy in
                    List {
                        Section("接口（\(shown.count)）") {
                            ForEach(shown) { endpoint in row(endpoint).id(endpoint.id) }
                        }
                        if !map.unmatched.isEmpty && !unusedOnly {
                            Section("前端调了、后端没对上（\(map.unmatched.count)）") {
                                ForEach(map.unmatched) { use in useRow(use, indent: false) }
                            }
                        }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .onAppear { reveal(proxy) }
                    .onChange(of: model.callMap.endpointFocus) { reveal(proxy) }
                }
            }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = model.callMap.endpointFocus else { return }
        open.insert(id)
        proxy.scrollTo(id, anchor: .top)
    }

    private var toolbar: some View {
        let requests = map.uses.values.reduce(0) { $0 + $1.count }
        return HStack(spacing: 10) {
            Text("后端 \(map.endpoints.count) 个接口 · 前端 \(requests) 处请求对上了\(map.unmatched.isEmpty ? "" : " · \(map.unmatched.count) 处没对上")")
                .themedFont(.caption, points: 10).foregroundStyle(.secondary)
            Spacer()
            Toggle("只看没有前端调用的", isOn: $unusedOnly).toggleStyle(.checkbox).themedFont(.caption, points: 10)
            Menu {
                let linked = Set(model.linkedProjects)
                if model.linkableProjects.isEmpty { Text("项目轨里没有别的项目") }
                ForEach(model.linkableProjects) { project in
                    Toggle(project.name, isOn: Binding(get: { linked.contains(project.rootPath) },
                                                       set: { model.setLinked(project.rootPath, $0) }))
                }
            } label: {
                Text(model.linkedProjects.isEmpty ? "关联项目" : "关联项目（\(model.linkedProjects.count)）").themedFont(.caption, points: 10)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("前端和后端在两个仓库时，把另一个也加进来一起配对。只读那个项目的文件，不改它。")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func row(_ endpoint: Endpoint) -> some View {
        let uses = map.uses(of: endpoint)
        let expanded = open.contains(endpoint.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button { if expanded { open.remove(endpoint.id) } else { open.insert(endpoint.id) } } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12)
                        .opacity(uses.isEmpty ? 0 : 1)
                }
                .buttonStyle(.plain).disabled(uses.isEmpty)
                Text(endpoint.methodLabel).themedFont(.caption2.monospaced().weight(.semibold), points: 9)
                    .padding(.horizontal, 4).padding(.vertical, 1).themedCapsule(ThemeColor(token: .selectedFill))
                Text(endpoint.path).themedFont(.callout.monospaced(), points: 12).lineLimit(1).truncationMode(.middle)
                if let project = endpoint.project { projectTag(project) }
                if let handler = endpoint.handler, model.callMap.turnChanged.contains(handler.id) { CallTurnTag() }
                Spacer(minLength: 6)
                Text(uses.isEmpty ? "没找到前端调用" : "\(uses.count) 处调用\(uses.contains { !$0.certain } ? "（含可能）" : "")")
                    .themedFont(.caption, points: 10).foregroundStyle(uses.isEmpty ? .tertiary : .secondary)
                if let handler = endpoint.handler, endpoint.project == nil {
                    Button(handler.name.contains("(") ? "调用关系" : handler.name) { model.callMap.mode = .tree; model.focusCall(handler) }
                        .buttonStyle(.link).themedFont(.caption, points: 10).lineLimit(1).frame(maxWidth: 140)
                        .help("看这个接口的处理函数往下调了谁")
                }
                Button("\((endpoint.file as NSString).lastPathComponent):\(endpoint.line)") {
                    model.openEndpointPlace(project: endpoint.project, path: endpoint.file, line: endpoint.line)
                }
                .buttonStyle(.link).themedFont(.caption, points: 10).lineLimit(1).help(endpoint.file)
            }
            if expanded {
                ForEach(uses) { use in useRow(use, indent: true) }
            }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(ThemeColor(token: .selectedFill, opacity: model.callMap.endpointFocus == endpoint.id ? 0.5 : 0)))
    }

    private func useRow(_ use: EndpointUse, indent: Bool) -> some View {
        HStack(spacing: 6) {
            Text(use.method ?? "?").themedFont(.caption2.monospaced(), points: 9).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text(use.path).themedFont(.caption.monospaced(), points: 10).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text(use.caller).themedFont(.callout, points: 12).lineLimit(1)
            if let project = use.project { projectTag(project) }
            if !use.certain {
                Text("可能").themedFont(.caption2, points: 9).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1).themedCapsule(ThemeColor(token: .selectedFill))
                    .help("只有路径的后半段对上：前端有 baseURL，或者后端的路由挂在别处的前缀下")
            }
            Spacer(minLength: 6)
            Button("\((use.file as NSString).lastPathComponent):\(use.line)") { model.openEndpointPlace(project: use.project, path: use.file, line: use.line) }
                .buttonStyle(.link).themedFont(.caption, points: 10).lineLimit(1).help(use.file)
        }
        .padding(.leading, indent ? 30 : 0)
    }

    private func projectTag(_ name: String) -> some View {
        Text(name).themedFont(.caption2, points: 9).foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(Capsule().stroke(ThemeColor(token: .border), lineWidth: 1))
    }
}
