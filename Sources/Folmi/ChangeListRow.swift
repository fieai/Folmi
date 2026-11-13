import Foundation
import FolmiCore

/// A flat sequence of visible rows lets both layouts use the same selectable list.
enum ChangeListRow: Identifiable, Equatable {
    case file(FileChange, depth: Int)
    case folder(String, depth: Int, expanded: Bool)

    var id: String {
        // Replacing a file with a directory can put both at the same path.
        switch self {
        case let .file(file, _): return "file:" + file.id
        case let .folder(path, _, _): return "folder:" + path
        }
    }

    var fileID: String? {
        if case let .file(file, _) = self { return file.id }
        return nil
    }

    static let automaticGroupingThreshold = 500

    static var forcedGroupingHelp: String {
        "改动超过 \(automaticGroupingThreshold) 个，只能按文件夹展示。"
    }

    static func rows(_ files: [FileChange], grouped: Bool, collapsed: Set<String>,
                     expanded: Set<String> = []) -> [Self] {
        ChangeListTree(files).rows(grouped: grouped, collapsed: collapsed, expanded: expanded)
    }
}

/// Build the directory index once per input list, independently of which folders are open.
struct ChangeListTree: Sendable {
    let files: [FileChange]
    private var filesByFolder: [String: [FileChange]] = [:]
    private var foldersByParent: [String: [String]] = [:]
    private(set) var counts: [String: Int] = [:]
    var forcedGrouping: Bool { files.count > ChangeListRow.automaticGroupingThreshold }

    init(_ files: [FileChange]) {
        self.files = files
        for file in files {
            let parts = file.path.split(separator: "/")
            let directory = parts.dropLast().joined(separator: "/")
            filesByFolder[directory, default: []].append(file)
            var parent = ""
            for component in parts.dropLast() {
                let path = parent.isEmpty ? String(component) : parent + "/" + component
                if counts[path] == nil { foldersByParent[parent, default: []].append(path) }
                counts[path, default: 0] += 1
                parent = path
            }
        }
        for parent in foldersByParent.keys {
            foldersByParent[parent]?.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    func rows(grouped: Bool, collapsed: Set<String>, expanded: Set<String>) -> [ChangeListRow] {
        guard grouped || forcedGrouping else { return files.map { .file($0, depth: 0) } }
        var result: [ChangeListRow] = []
        func appendRows(in path: String, depth: Int) {
            for folder in foldersByParent[path] ?? [] {
                let open = forcedGrouping ? expanded.contains(folder) : !collapsed.contains(folder)
                result.append(.folder(folder, depth: depth, expanded: open))
                if open { appendRows(in: folder, depth: depth + 1) }
            }
            for file in filesByFolder[path] ?? [] { result.append(.file(file, depth: depth)) }
        }
        appendRows(in: "", depth: 0)
        return result
    }
}

/// Memoization stays outside observation: reading a cached projection must not schedule another render.
final class ChangeListRowCache {
    // Navigation bookkeeping must not invalidate an already visible list.
    var revealedSelection: String?
    private var inputKey: String?
    private var filteredFiles: [FileChange] = []
    private var tree: ChangeListTree?
    private var grouped = false
    private var collapsed: Set<String> = []
    private var expanded: Set<String> = []
    private var result: [ChangeListRow] = []
    private(set) var computationCount = 0

    var counts: [String: Int] { tree?.counts ?? [:] }

    func files(_ snapshot: RepositorySnapshot?, in area: ChangeArea, query: String,
               prepared: ChangeListTree? = nil) -> [FileChange] {
        guard let snapshot else { inputKey = nil; filteredFiles = []; return [] }
        let key = snapshot.root.path + ":" + snapshot.fingerprint + ":" + area.rawValue + ":" + query
        if key != inputKey {
            if query.isEmpty, let prepared { filteredFiles = prepared.files }
            else {
                filteredFiles = snapshot.files.filter {
                    (area == .working ? $0.hasWorking : $0.hasStaged) && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query))
                }
            }
            inputKey = key
        }
        return filteredFiles
    }

    func rows(_ files: [FileChange], grouped: Bool, collapsed: Set<String>, expanded: Set<String>,
              prepared: ChangeListTree? = nil) -> [ChangeListRow] {
        let changed = tree?.files != files
        if changed { tree = prepared ?? ChangeListTree(files) }
        if changed || self.grouped != grouped || self.collapsed != collapsed || self.expanded != expanded {
            result = tree!.rows(grouped: grouped, collapsed: collapsed, expanded: expanded)
            self.grouped = grouped; self.collapsed = collapsed; self.expanded = expanded
            computationCount += 1
        }
        return result
    }
}

/// Prepare both groups before publishing a snapshot, so the first visible projection only walks open folders.
struct ChangeListInput: Sendable {
    let root: URL
    let fingerprint: String
    let staged: ChangeListTree
    let working: ChangeListTree

    static func prepare(_ snapshot: RepositorySnapshot) async -> Self? {
        guard snapshot.files.count > ChangeListRow.automaticGroupingThreshold else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self(root: snapshot.root, fingerprint: snapshot.fingerprint,
                 staged: ChangeListTree(snapshot.files.filter(\.hasStaged)),
                 working: ChangeListTree(snapshot.files.filter(\.hasWorking)))
        }.value
    }
}
