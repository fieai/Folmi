import Darwin
import Foundation
import FolmiCore
import SwiftUI

struct ProjectFileNode: Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let children: [ProjectFileNode]?
    let notice: String?
    /// Covered by `.gitignore` or a dependency/build folder: shown dimmed, not counted toward the file limit.
    let isIgnored: Bool
    /// An ignored folder whose contents are read only when it is opened.
    let isDeferred: Bool

    init(name: String, path: String, isDirectory: Bool, children: [ProjectFileNode]?, notice: String? = nil,
         isIgnored: Bool = false, isDeferred: Bool = false) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.children = children
        self.notice = notice
        self.isIgnored = isIgnored
        self.isDeferred = isDeferred
    }
}

struct ProjectTreeSnapshot: Sendable {
    let roots: [ProjectFileNode]
    let fileCount: Int
    let isTruncated: Bool
    let notice: String?
}

enum ProjectTreeError: Error, LocalizedError {
    case protectedRoot
    case invalidRoot
    case cannotReadRoot(String)

    var errorDescription: String? {
        switch self {
        case .protectedRoot: return "项目文件树不读取 Git 元数据目录。"
        case .invalidRoot: return "项目目录不可用，或它是符号链接。"
        case .cannotReadRoot(let detail): return "无法读取项目目录：\(detail)"
        }
    }
}

/// Directory names and file attributes only; no file contents or Git metadata are read.
enum ProjectFileTree {
    struct ScanLimits {
        let maximumFiles: Int
        let maximumEntries: Int
        let maximumDepth: Int

        static let `default` = ScanLimits(maximumFiles: 10_000, maximumEntries: 20_000, maximumDepth: 64)
    }

    static func scan(root: URL, ignored: IgnoredPaths = IgnoredPaths()) throws -> ProjectTreeSnapshot {
        try scan(root: root, ignored: ignored, limits: .default)
    }

    /// Ignored folders are left closed (`isDeferred`); `loadFolder` reads one when it is opened.
    static func scan(root: URL, ignored: IgnoredPaths = IgnoredPaths(), limits: ScanLimits) throws -> ProjectTreeSnapshot {
        let descriptor = try openRoot(root)
        var scanner = Scanner(limits: limits, ignored: ignored)
        let roots: [ProjectFileNode]
        do {
            // readDirectory owns and closes its directory descriptor.
            roots = try scanner.readDirectory(descriptor: descriptor, path: "", depth: 0, insideIgnored: false)
        } catch {
            throw ProjectTreeError.cannotReadRoot(error.localizedDescription)
        }
        return ProjectTreeSnapshot(roots: roots, fileCount: scanner.fileCount,
                                   isTruncated: scanner.isTruncated,
                                   notice: scanner.notices.isEmpty ? nil : scanner.notices.joined(separator: "；"))
    }

    /// One level of an ignored folder; its subfolders stay closed until they are opened in turn.
    static func loadFolder(root: URL, path: String, limits: ScanLimits = .default) throws -> ProjectTreeSnapshot {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }),
              !containsGitComponent(path) else { throw ProjectTreeError.invalidRoot }
        var descriptor = try openRoot(root)
        // Walk down from the open root one name at a time; O_NOFOLLOW rejects any symlink along the way.
        for component in components {
            let child = component.withCString { openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            let savedError = errno
            close(descriptor)
            guard child >= 0 else { throw ProjectTreeError.cannotReadRoot(systemError(savedError)) }
            descriptor = child
        }
        var scanner = Scanner(limits: limits, ignored: IgnoredPaths())
        let children = try scanner.readDirectory(descriptor: descriptor, path: path, depth: components.count, insideIgnored: true)
        return ProjectTreeSnapshot(roots: children, fileCount: scanner.fileCount, isTruncated: scanner.isTruncated,
                                   notice: scanner.notices.isEmpty ? nil : scanner.notices.joined(separator: "；"))
    }

    /// The tree with the folder at `path` filled in by `loadFolder`.
    static func replacingChildren(in nodes: [ProjectFileNode], path: String, with loaded: ProjectTreeSnapshot) -> [ProjectFileNode] {
        nodes.map { node in
            guard node.isDirectory, path == node.path || path.hasPrefix(node.path + "/") else { return node }
            if node.path == path {
                return ProjectFileNode(name: node.name, path: node.path, isDirectory: true, children: loaded.roots,
                                       notice: loaded.notice, isIgnored: node.isIgnored)
            }
            return ProjectFileNode(name: node.name, path: node.path, isDirectory: true,
                                   children: replacingChildren(in: node.children ?? [], path: path, with: loaded),
                                   notice: node.notice, isIgnored: node.isIgnored, isDeferred: node.isDeferred)
        }
    }

    private static func openRoot(_ root: URL) throws -> Int32 {
        guard root.isFileURL else { throw ProjectTreeError.invalidRoot }
        guard !containsGitComponent(root.path) else { throw ProjectTreeError.protectedRoot }
        var rootAttributes = stat()
        guard root.path.withCString({ lstat($0, &rootAttributes) }) == 0,
              rootAttributes.st_mode & S_IFMT == S_IFDIR else {
            throw ProjectTreeError.invalidRoot
        }
        // POSIX canonicalization also unifies macOS /var and /private/var spellings.
        guard let canonicalPointer = root.path.withCString({ realpath($0, nil) }) else {
            throw ProjectTreeError.invalidRoot
        }
        defer { free(canonicalPointer) }
        let canonicalPath = String(cString: canonicalPointer)
        guard !containsGitComponent(canonicalPath) else { throw ProjectTreeError.protectedRoot }
        let descriptor = canonicalPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw ProjectTreeError.cannotReadRoot(systemError()) }
        return descriptor
    }

    static func filtered(_ roots: [ProjectFileNode], query: String) -> [ProjectFileNode] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return roots }
        return roots.compactMap { node in
            if node.path.localizedStandardContains(needle) { return node }
            guard node.isDirectory else { return nil }
            let children = filtered(node.children ?? [], query: needle)
            guard !children.isEmpty else { return nil }
            return ProjectFileNode(name: node.name, path: node.path, isDirectory: true,
                                   children: children, notice: node.notice, isIgnored: node.isIgnored, isDeferred: node.isDeferred)
        }
    }

    private static func containsGitComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.caseInsensitiveCompare(".git") == .orderedSame }
    }

    private static func systemError(_ code: Int32 = errno) -> String {
        String(cString: strerror(code))
    }

    private struct Entry {
        let name: String
        let isDirectory: Bool
        let isIgnored: Bool
    }

    private struct Scanner {
        let limits: ScanLimits
        let ignored: IgnoredPaths
        var visitedEntries = 0
        var fileCount = 0
        var isTruncated = false
        var notices: [String] = []

        /// Dependency and build folders: treated as ignored even where `.gitignore` does not say so.
        private static let excludedDirectories: Set<String> = [
            "node_modules", ".build", "build", "vendor", "dist", "__pycache__",
            ".venv", "venv", ".next", ".nuxt", ".cache", "coverage", ".gradle",
            "deriveddata", "pods", "carthage", "target"
        ]
        /// Files the system leaves behind (Finder's folder settings, AppleDouble, Windows thumbnails): never project files.
        static let excludedFiles: Set<String> = [".ds_store", "thumbs.db", "desktop.ini", ".localized"]

        mutating func addNotice(_ message: String) {
            if !notices.contains(message), notices.count < 6 { notices.append(message) }
        }

        mutating func truncate(_ message: String) {
            isTruncated = true
            addNotice(message)
        }

        mutating func readDirectory(descriptor: Int32, path: String, depth: Int, insideIgnored: Bool) throws -> [ProjectFileNode] {
            guard let directory = fdopendir(descriptor) else {
                let savedError = errno
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: savedError) ?? .EIO)
            }
            defer { closedir(directory) }
            var entries: [Entry] = []
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    break
                }
                let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(validatingCString: $0)
                    }
                }
                guard let name else {
                    guard visitedEntries < limits.maximumEntries else {
                        truncate("目录项超过 \(limits.maximumEntries.formatted()) 个，仅显示已扫描部分")
                        break
                    }
                    visitedEntries += 1
                    addNotice("部分文件名无法作为 UTF-8 显示，已跳过")
                    continue
                }
                if name == "." || name == ".." { continue }
                guard visitedEntries < limits.maximumEntries else {
                    truncate("目录项超过 \(limits.maximumEntries.formatted()) 个，仅显示已扫描部分")
                    break
                }
                visitedEntries += 1
                // Exclude .git before even looking up its attributes, including linked-worktree .git files.
                if name.caseInsensitiveCompare(".git") == .orderedSame { continue }
                var attributes = stat()
                let result = name.withCString { fstatat(descriptor, $0, &attributes, AT_SYMLINK_NOFOLLOW) }
                guard result == 0 else {
                    addNotice("部分目录项无法读取，已跳过")
                    continue
                }
                let type = attributes.st_mode & S_IFMT
                if type == S_IFLNK { continue }
                let isDirectory = type == S_IFDIR
                guard isDirectory || type == S_IFREG else { continue }
                if !isDirectory && (Self.excludedFiles.contains(name.lowercased()) || name.hasPrefix("._")) { continue }
                let childPath = path.isEmpty ? name : path + "/" + name
                let isIgnored = insideIgnored || (isDirectory ? Self.excludedDirectories.contains(name.lowercased())
                                                                  || ignored.directories.contains(childPath)
                                                              : ignored.files.contains(childPath))
                entries.append(Entry(name: name, isDirectory: isDirectory, isIgnored: isIgnored))
            }
            entries.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.name < $1.name : comparison == .orderedAscending
            }
            var nodes: [ProjectFileNode] = []
            for entry in entries {
                let childPath = path.isEmpty ? entry.name : path + "/" + entry.name
                if entry.isDirectory && entry.isIgnored {
                    nodes.append(ProjectFileNode(name: entry.name, path: childPath, isDirectory: true,
                                                 children: [], isIgnored: true, isDeferred: true))
                } else if entry.isDirectory {
                    if depth >= limits.maximumDepth {
                        truncate("目录层级超过 \(limits.maximumDepth) 层，深层内容未加载")
                        nodes.append(ProjectFileNode(name: entry.name, path: childPath, isDirectory: true,
                                                     children: [], notice: "目录层级过深，未继续加载"))
                        continue
                    }
                    if visitedEntries >= limits.maximumEntries {
                        truncate("目录项达到 \(limits.maximumEntries.formatted()) 个，部分目录未加载")
                        nodes.append(ProjectFileNode(name: entry.name, path: childPath, isDirectory: true,
                                                     children: [], notice: "扫描已达到数量上限"))
                        continue
                    }
                    // Descend relative to an already-open directory. O_NOFOLLOW rejects any swapped-in symlink.
                    let childDescriptor = entry.name.withCString {
                        openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                    guard childDescriptor >= 0 else {
                        addNotice("部分子目录无法读取，已保留提示")
                        nodes.append(ProjectFileNode(name: entry.name, path: childPath, isDirectory: true,
                                                     children: [], notice: "无法读取此目录：\(ProjectFileTree.systemError())"))
                        continue
                    }
                    do {
                        let children = try readDirectory(descriptor: childDescriptor, path: childPath, depth: depth + 1,
                                                         insideIgnored: false)
                        nodes.append(ProjectFileNode(name: entry.name, path: childPath, isDirectory: true, children: children))
                    } catch {
                        addNotice("部分子目录读取失败，已保留提示")
                        nodes.append(ProjectFileNode(name: entry.name, path: childPath, isDirectory: true,
                                                     children: [], notice: "读取目录失败：\(error.localizedDescription)"))
                    }
                } else if entry.isIgnored {
                    nodes.append(ProjectFileNode(name: entry.name, path: childPath, isDirectory: false, children: nil, isIgnored: true))
                } else {
                    guard fileCount < limits.maximumFiles else {
                        truncate("文件超过 \(limits.maximumFiles.formatted()) 个，仅显示已加载部分")
                        continue
                    }
                    fileCount += 1
                    nodes.append(ProjectFileNode(name: entry.name, path: childPath, isDirectory: false, children: nil))
                }
            }
            return nodes
        }
    }
}

/// Which folders of the file tree are open.
@MainActor
final class ProjectTreeExpansion: ObservableObject {
    @Published var expandedPaths: Set<String> = []
    @Published var searchCollapsedPaths: Set<String> = []
    var seededExpansion = false
    func reset() { expandedPaths = []; searchCollapsedPaths = []; seededExpansion = false }
}

struct ProjectFileTreeView: View {
    let nodes: [ProjectFileNode]
    let query: String
    let selectedPath: String?
    let changedPaths: Set<String>
    let busy: Bool
    let onOpen: (String) -> Void
    /// Status letter per changed path (M, A, D, ?).
    var changeCodes: [String: String] = [:]
    /// Task boxes of Markdown files that have any.
    var taskCounts: [String: TaskCount] = [:]
    var root: URL?
    /// Right-click actions the window provides: show a changed file's diff, cd the terminal there, paste the path.
    var onShowChanges: ((String) -> Void)?
    var onTerminalHere: ((String, Bool) -> Void)?
    var onSendPath: ((String) -> Void)?
    /// 忽略: adds the path to the root .gitignore (true for a folder).
    var onIgnore: ((String, Bool) -> Void)?
    /// Reads an ignored folder the first time it is shown open.
    var onLoadFolder: ((String) -> Void)?
    @State private var hovered: String?
    @FocusState private var focused: Bool

    /// Owned by the window, so switching the left block's tabs keeps which folders are open.
    @ObservedObject var expansion: ProjectTreeExpansion

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @ViewBuilder private func menu(_ node: ProjectFileNode, changed: Bool) -> some View {
        if !node.isDirectory {
            Button("打开") { onOpen(node.path) }
            if changed, let onShowChanges { Button("看改动") { onShowChanges(node.path) } }
            if let root { Button("快速查看") { QuickLookPreview.shared.toggle(root.appendingPathComponent(node.path)) } }
            Divider()
        }
        if let onSendPath { Button("把路径发到终端") { onSendPath(node.path) } }
        if let onTerminalHere { Button(node.isDirectory ? "在终端中进入这个文件夹" : "在终端中进入所在文件夹") { onTerminalHere(node.path, node.isDirectory) } }
        if let onIgnore {
            Button(node.isDirectory ? "忽略这个文件夹（加进 .gitignore）" : "忽略这个文件（加进 .gitignore）") { onIgnore(node.path, node.isDirectory) }
        }
        if let root {
            Divider()
            FileActionsMenu(url: root.appendingPathComponent(node.path), relativePath: node.path)
        }
    }

    var body: some View {
        let _ = PerfLog.body("ProjectFileTreeView")
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(visibleRows) { row in
                    if let node = row.node {
                        let changed = !node.isDirectory && changedPaths.contains(node.path)
                        ProjectTreeRow(node: node, depth: row.depth, expanded: node.isDirectory && isExpanded(node.path),
                                       selected: selectedPath == node.path && !node.isDirectory,
                                       changeCode: changed ? (changeCodes[node.path] ?? "M") : nil,
                                       taskCount: node.isDirectory ? nil : taskCounts[node.path], busy: busy,
                                       onPress: {
                                           focused = true
                                           if node.isDirectory { toggle(node.path) } else { onOpen(node.path) }
                                       },
                                       onHover: { inside in
                                           if inside { hovered = node.isDirectory ? nil : node.path } else if hovered == node.path { hovered = nil }
                                       })
                        .equatable()
                        .contextMenu { menu(node, changed: changed) }
                    } else {
                        Text(row.notice ?? "空文件夹")
                            .themedFont(.system(size: 11), points: 11).foregroundStyle(.secondary)
                            .padding(.leading, CGFloat(row.depth * 14 + 27)).padding(.vertical, 5)
                            .onAppear { if let path = row.loadPath { onLoadFolder?(path) } }
                    }
                }
            }.padding(.horizontal, 6).padding(.vertical, 5)
        }
        .focusable().focusEffectDisabled().focused($focused)
        // Space: Quick Look of the file under the pointer, else the open one (like Finder).
        .onKeyPress(.space) {
            guard let root, let path = hovered ?? selectedPath else { return .ignored }
            QuickLookPreview.shared.toggle(root.appendingPathComponent(path))
            return .handled
        }
        .onAppear { seedExpansion() }
        .onChange(of: nodes) { _, _ in seedExpansion() }
        .onChange(of: query) { _, _ in expansion.searchCollapsedPaths.removeAll() }
        .onChange(of: selectedPath) { _, path in reveal(path) }
    }

    private struct Row: Identifiable {
        let id: String
        let node: ProjectFileNode?
        let depth: Int
        let notice: String?
        /// The ignored folder this placeholder row stands for, read when the row appears.
        var loadPath: String? = nil
    }

    private var visibleRows: [Row] {
        var rows: [Row] = []
        func append(_ children: [ProjectFileNode], depth: Int) {
            for node in children {
                rows.append(Row(id: node.path, node: node, depth: depth, notice: nil))
                guard node.isDirectory && isExpanded(node.path) else { continue }
                if node.isDeferred {
                    rows.append(isSearching
                        ? Row(id: node.path + "/:deferred", node: nil, depth: depth + 1, notice: "被忽略的文件夹，清空搜索后展开查看")
                        : Row(id: node.path + "/:loading", node: nil, depth: depth + 1, notice: "读取中…", loadPath: node.path))
                } else if let notice = node.notice {
                    rows.append(Row(id: node.path + "/:notice", node: nil, depth: depth + 1, notice: notice))
                } else if node.children?.isEmpty != false {
                    rows.append(Row(id: node.path + "/:empty", node: nil, depth: depth + 1, notice: nil))
                } else {
                    append(node.children ?? [], depth: depth + 1)
                }
            }
        }
        append(ProjectFileTree.filtered(nodes, query: query), depth: 0)
        return rows
    }

    private func isExpanded(_ path: String) -> Bool {
        isSearching ? !expansion.searchCollapsedPaths.contains(path) : expansion.expandedPaths.contains(path)
    }

    private func toggle(_ path: String) {
        if isSearching {
            if !expansion.searchCollapsedPaths.insert(path).inserted { expansion.searchCollapsedPaths.remove(path) }
        } else if !expansion.expandedPaths.insert(path).inserted { expansion.expandedPaths.remove(path) }
    }

    private func seedExpansion() {
        guard !expansion.seededExpansion && !nodes.isEmpty else { return }
        expansion.seededExpansion = true
        let common: Set<String> = ["src", "sources", "app", "lib", "scripts", "tests", "examples", "demo"]
        expansion.expandedPaths.formUnion(nodes.filter { $0.isDirectory && common.contains($0.name.lowercased()) }.map(\.path))
        reveal(selectedPath)
    }

    private func reveal(_ path: String?) {
        guard let path else { return }
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return }
        let folders = (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
        // Inserting a folder that is already open would still publish and re-render the whole tree.
        if !expansion.expandedPaths.isSuperset(of: folders) { expansion.expandedPaths.formUnion(folders) }
    }
}

/// One row of the file tree. Compared by what it shows (its closures only capture the node), so selecting a file
/// re-renders the two rows whose highlight changed, not every visible row.
private struct ProjectTreeRow: View, Equatable {
    let node: ProjectFileNode
    let depth: Int
    let expanded: Bool
    let selected: Bool
    /// Status letter when the file has changes (M, A, D, ?).
    let changeCode: String?
    let taskCount: TaskCount?
    let busy: Bool
    let onPress: () -> Void
    let onHover: (Bool) -> Void
    @Environment(\.folmiTheme) private var theme

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.node.path == b.node.path && a.node.name == b.node.name && a.node.isDirectory == b.node.isDirectory
            && a.node.notice == b.node.notice && a.node.isIgnored == b.node.isIgnored && a.node.isDeferred == b.node.isDeferred
            && a.depth == b.depth && a.expanded == b.expanded && a.selected == b.selected
            && a.changeCode == b.changeCode && a.taskCount == b.taskCount && a.busy == b.busy
    }

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                    .opacity(node.isDirectory ? 1 : 0)
                Group {
                    Image(systemName: icon).foregroundStyle(node.isDirectory ? ThemeColor(token: .accent) : ThemeColor(token: .secondaryText))
                        .font(.system(size: 13)).frame(width: 16)
                    Text(node.name).themedFont(.system(size: 12), points: 12).lineLimit(1).truncationMode(.middle)
                }
                // Ignored by Git: still browsable, but visibly not part of the project.
                .opacity(node.isIgnored ? 0.5 : 1)
                Spacer(minLength: 4)
                if node.notice != nil {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.themed(.modified))
                }
                if let taskCount, taskCount.total > 0 { TaskRing(count: taskCount) }
                if let code = changeCode {
                    let token: ThemeToken = code == "D" ? .removed : (code == "A" || code == "?") ? .added : .modified
                    Group {
                        if theme.style.solidMarks {
                            StatusBadge(letter: code == "?" ? "A" : code, token: token, size: 14)
                        } else {
                            Text(code == "?" ? "A" : code).themedFont(.system(size: 9, weight: .bold, design: .monospaced), points: 9)
                                .foregroundStyle(ThemeColor(token: token))
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(code == "D" ? "已删除" : (code == "A" || code == "?") ? "新增" : "有改动")
                }
            }
            .padding(.leading, CGFloat(depth * 14 + 5)).padding(.trailing, 7).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // The tree keeps its own colors on a selected row, so even 石墨 uses the neutral (unfocused) selection here.
            .background { SelectedRowBackground(selected: selected, focused: false, inset: false) }
        }
        .buttonStyle(.pressableRow).disabled(busy)
        .onHover(perform: onHover)
        .help(node.notice.map { "\(node.path)\n\($0)" } ?? (node.isIgnored ? "\(node.path)\n已被 Git 忽略" : node.path))
        .accessibilityLabel((node.isDirectory ? "\(node.name)，文件夹" : node.name) + (node.isIgnored ? "，已被 Git 忽略" : ""))
        .accessibilityValue(node.isDirectory ? (expanded ? "已展开" : "已折叠") : (selected ? "已选中" : ""))
    }

    private var icon: String {
        if node.isDirectory { return expanded ? "folder.fill" : "folder" }
        let ext = (node.name as NSString).pathExtension.lowercased()
        switch ext {
        case "js", "jsx", "ts", "tsx", "json": return "curlybraces"
        case "py", "swift", "rs", "go", "c", "cpp", "h", "sh": return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        default: return "doc.text"
        }
    }
}
