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

    static func rows(_ files: [FileChange], grouped: Bool, collapsed: Set<String>) -> [Self] {
        guard grouped else { return files.map { .file($0, depth: 0) } }

        let filesByFolder = Dictionary(grouping: files) { ($0.path as NSString).deletingLastPathComponent }
        var foldersByParent: [String: [String]] = [:]
        var folders: Set<String> = []
        for directory in filesByFolder.keys {
            var path = directory
            while !path.isEmpty && folders.insert(path).inserted {
                let parent = (path as NSString).deletingLastPathComponent
                foldersByParent[parent, default: []].append(path)
                path = parent
            }
        }

        var result: [Self] = []
        func appendRows(in path: String, depth: Int) {
            for folder in (foldersByParent[path] ?? []).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let expanded = !collapsed.contains(folder)
                result.append(.folder(folder, depth: depth, expanded: expanded))
                if expanded { appendRows(in: folder, depth: depth + 1) }
            }
            for file in filesByFolder[path] ?? [] {
                result.append(.file(file, depth: depth))
            }
        }
        appendRows(in: "", depth: 0)
        return result
    }
}
