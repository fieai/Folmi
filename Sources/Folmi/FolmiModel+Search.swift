import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// Quick open (⌘P) and project-wide text search (⌘⇧F).
extension FolmiModel {
    var quickOpenPaths: [String] {
        var seen = Set<String>()
        _ = editorChrome
        let recent = editorWorkspace?.documents.reversed().map(\.path) ?? []
        return (recent + browserPaths).filter { seen.insert($0).inserted }
    }

    func openQuickOpen() {
        guard !busy, repositoryURL != nil, !showDelivery, !showActivity, !showProjectSearch else { return }
        showQuickOpen = true
    }

    func openProjectSearch() {
        guard !busy, repositoryURL != nil, !showDelivery, !showActivity, !showQuickOpen else { return }
        showProjectSearch = true
        if !projectSearchQuery.isEmpty { performProjectSearch() }
    }

    func openQuickMatch(_ match: QuickOpenMatch) {
        guard !busy, let editorWorkspace else { return }
        do {
            try editorWorkspace.reveal(path: match.path, line: match.line, column: match.column)
            targetDiff(path: match.path)
            content = .editor
            showQuickOpen = false
            scheduleSave()
        } catch { report(error, title: "打开文件失败") }
    }

    func openSearchHit(_ hit: ProjectSearchHit) {
        guard !busy, let editorWorkspace else { return }
        do {
            // Disk ranges include original BOM/CRLF; line/column target the normalized editor buffer.
            try editorWorkspace.reveal(path: hit.path, line: hit.line, column: hit.column)
            if let state = editorWorkspace.tabStates[hit.path] {
                try editorWorkspace.reveal(path: hit.path,
                    range: NSRange(location: state.selectionLocation, length: hit.range.length))
            }
            targetDiff(path: hit.path)
            content = .editor
            showProjectSearch = false
            cancelProjectSearch()
            scheduleSave()
        } catch { report(error, title: "打开搜索命中失败") }
    }

    func scheduleSearch() {
        guard !restoring, showProjectSearch else { return }
        searchTask?.cancel()
        searchWorker?.cancel()
        searchRevision = UUID()
        if projectSearchQuery.isEmpty { projectSearchResult = nil; projectSearching = false; return }
        projectSearchResult = nil
        projectSearching = true
        searchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            self?.performProjectSearch()
        }
    }

    func performProjectSearch() {
        guard let root = repositoryURL, !projectSearchQuery.isEmpty else { return }
        searchTask?.cancel()
        searchWorker?.cancel()
        let revision = UUID(); searchRevision = revision
        let paths = browserPaths, query = projectSearchQuery, sensitive = searchCaseSensitive
        let documents = Dictionary(uniqueKeysWithValues: (editorWorkspace?.documents ?? []).filter { $0.preview == nil }.map { ($0.path, $0.text) })
        projectSearching = true
        projectSearchResult = nil
        let worker = Task.detached(priority: .userInitiated) {
            try ProjectTextSearch.search(root: root, paths: paths, query: query, caseSensitive: sensitive,
                                        openDocuments: documents, isCancelled: { Task.isCancelled })
        }
        searchWorker = worker
        searchTask = Task { [weak self] in
            do {
                let result = try await worker.value
                guard let self, self.searchRevision == revision, self.repositoryURL == root else { return }
                self.projectSearchResult = result
                self.projectSearching = false
            } catch {
                guard let self, self.searchRevision == revision else { return }
                self.projectSearching = false
                if !(error is CancellationError) { self.report(error, title: "项目搜索失败") }
            }
        }
    }

    func cancelProjectSearch() {
        searchRevision = UUID()
        searchTask?.cancel(); searchWorker?.cancel()
        searchTask = nil; searchWorker = nil
        projectSearching = false
    }
}
