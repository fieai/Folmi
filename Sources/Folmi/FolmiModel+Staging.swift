import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// Selecting changed files, reading their diffs, and staging or unstaging files, hunks and lines.
extension FolmiModel {
    func selectFile(_ file: FileChange) { selectFiles([file.id]) }

    func selectFiles(_ ids: Set<String>) {
        guard !busy else { return }
        diffSwitchStart = .now; PerfLog.resetBodies()
        selectedFileIDs = ids; selectedFileID = filesInArea.first { ids.contains($0.id) }?.id; content = .diff
        scheduleSave()
        // Already read (prefetched or seen before): shown in the same update as the selection, one render instead of two.
        let files = filesInArea.filter { ids.contains($0.id) }
        let cached = files.compactMap { cachedDiff($0, area: area) }
        if !files.isEmpty, cached.count == files.count {
            diffRequest = UUID(); selectedLines = [:]
            fileDiffs = cached; fileDiff = cached.first
            prefetchNeighbours(of: selectedFileID)
            if let start = diffSwitchStart {
                diffSwitchStart = nil
                let detail = "\(cached[0].file.path) cached"
                PerfLog.interval("switch.diffData", since: start, detail: detail)
                PerfLog.afterFrame { PerfLog.interval("switch.diffFrame", since: start, detail: detail) }
            }
            return
        }
        Task { await updateDiff() }
    }

    /// The review page's current change, mirrored in the change list without leaving the page: the row of the file
    /// being reviewed is the selected one, and the 差异 tab behind it shows that file.
    func followReview(_ diff: FileDiff) {
        guard content == .allChanges, area != diff.area || selectedFileIDs != [diff.file.id] || selectedFileID != diff.file.id else { return }
        if area != diff.area { area = diff.area; scheduleSave() }
        selectedFileIDs = [diff.file.id]; selectedFileID = diff.file.id
        // The page's diff is current: no read, and a read still under way must not land over it.
        diffRequest = UUID(); selectedLines = [:]
        fileDiffs = [diff]; fileDiff = diff
    }

    /// Selecting rows in the other group of the change list moves to that area without clearing first.
    func selectFiles(_ ids: Set<String>, in newArea: ChangeArea) {
        guard !busy else { return }
        if newArea != area { area = newArea; scheduleSave() }
        selectFiles(ids)
    }

    func setArea(_ newArea: ChangeArea) {
        guard !busy else { return }
        area = newArea; selectedFileID = nil; selectedFileIDs = []
        Task { await updateDiff() }; scheduleSave()
    }

    func updateDiff(keepingSelection: Bool = false) async {
        if let start = diffSwitchStart { PerfLog.interval("switch.taskStart", since: start) }
        let request = UUID(); diffRequest = request
        let previous = Dictionary(fileDiffs.map { ($0.file.path, $0.rawPatch) }, uniquingKeysWith: { first, _ in first })
        // The previous diff stays on screen until the new one is ready (usually from the cache, at once): no blank frame.
        if !keepingSelection { selectedLines = [:] }
        selectedFileIDs.formIntersection(Set(filesInArea.map(\.id)))
        if selectedFileIDs.isEmpty {
            // An explicitly opened clean file must not silently show another file's diff.
            if let target = selectedFileID, !filesInArea.contains(where: { $0.id == target }) {
                selectedLines = [:]; fileDiff = nil; fileDiffs = []; return
            }
            if let first = filesInArea.first { selectedFileIDs = [first.id] }
        }
        selectedFileID = filesInArea.first { selectedFileIDs.contains($0.id) }?.id
        guard repository != nil else { return }
        let files = filesInArea.filter { selectedFileIDs.contains($0.id) }
        guard files.count <= 50 else { report(FolmiFailure(message: "一次最多查看 50 个文件，请缩小选择。"), title: "选择过多"); return }
        if files.isEmpty { fileDiff = nil; fileDiffs = []; return }
        let requestedArea = area
        do {
            var results: [FileDiff] = []
            for file in files {
                let result = try await displayDiff(file, area: requestedArea)
                guard diffRequest == request, area == requestedArea else { return }
                results.append(result)
            }
            if keepingSelection {
                let unchanged = Set(results.filter { previous[$0.file.path] == $0.rawPatch }.map(\.file.path))
                selectedLines = selectedLines.filter { unchanged.contains($0.key) }
            }
            fileDiffs = results; fileDiff = results.first
            prefetchNeighbours(of: selectedFileID)
            if let start = diffSwitchStart {
                diffSwitchStart = nil
                let detail = results.first.map { "\($0.file.path) \($0.rawPatch.utf8.count)B" } ?? ""
                PerfLog.interval("switch.diffData", since: start, detail: detail)
                PerfLog.afterFrame { PerfLog.interval("switch.diffFrame", since: start, detail: detail) }
            }
        } catch {
            guard diffRequest == request else { return }
            fileDiff = nil; fileDiffs = []
            report(error, title: "读取差异失败")
        }
    }

    func toggleLine(_ id: Int, in diff: FileDiff) {
        guard !busy, diff.isPartialSupported else { return }
        if selectedLines[diff.file.path, default: []].contains(id) { selectedLines[diff.file.path]?.remove(id) }
        else { selectedLines[diff.file.path, default: []].insert(id) }
    }

    func stageSelectedFile() { if let file = selectedFile { stageFile(file) } }

    func stageFile(_ file: FileChange) { stageFile(file, succeeded: nil) }
    func stageFile(_ file: FileChange, succeeded: (() -> Void)?, after: (() -> Void)? = nil) {
        guard let repository, let state = snapshot else { return }
        let paths = [file.path] + (file.originalPath.map { [$0] } ?? [])
        mutateUndoable("暂存 \(file.path)", capture: { try await repository.captureIndex(paths) }, succeeded: succeeded, after: after) {
            try await repository.stage(file, expectedFingerprint: state.fingerprint); return file.path
        }
    }

    func unstageSelectedFile() { if let file = selectedFile { unstageFile(file) } }

    func unstageFile(_ file: FileChange) { unstageFile(file, succeeded: nil) }
    func unstageFile(_ file: FileChange, succeeded: (() -> Void)?) {
        guard let repository, let state = snapshot else { return }
        let paths = [file.path] + (file.originalPath.map { [$0] } ?? [])
        mutateUndoable("取消暂存 \(file.path)", capture: { try await repository.captureIndex(paths) }, succeeded: succeeded) {
            try await repository.unstage(file, expectedFingerprint: state.fingerprint); return file.path
        }
    }

    /// Several files in one step (and one undo): the selected rows, or a whole group.
    func stageFiles(_ files: [FileChange]) {
        guard let repository, let state = snapshot else { return }
        let files = files.filter(\.hasWorking)
        if files.count == 1 { stageFile(files[0]); return }
        guard !files.isEmpty else { return }
        let paths = files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        mutateUndoable("暂存 \(files.count) 个文件", capture: { try await repository.captureIndex(paths) }) {
            try await repository.stage(files, expectedFingerprint: state.fingerprint); return files.map(\.path).joined(separator: "\n")
        }
    }

    func unstageFiles(_ files: [FileChange]) {
        guard let repository, let state = snapshot else { return }
        let files = files.filter(\.hasStaged)
        if files.count == 1 { unstageFile(files[0]); return }
        guard !files.isEmpty else { return }
        let paths = files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        mutateUndoable("取消暂存 \(files.count) 个文件", capture: { try await repository.captureIndex(paths) }) {
            try await repository.unstage(files, expectedFingerprint: state.fingerprint); return files.map(\.path).joined(separator: "\n")
        }
    }

    /// The selected rows of the current group: staged when they are in 工作区, unstaged when in 暂存区.
    func toggleStageSelectedFiles() {
        let files = filesInArea.filter { selectedFileIDs.contains($0.id) }
        if area == .working { stageFiles(files) } else { unstageFiles(files) }
    }

    func stageAll() { stageFiles(snapshot?.files.filter(\.hasWorking) ?? []) }
    func unstageAll() { unstageFiles(snapshot?.files.filter(\.hasStaged) ?? []) }

    func applyHunk(_ hunk: DiffHunk, in diff: FileDiff) { apply(hunk, diff: diff, selected: nil) }

    func applySelectedLines(_ hunk: DiffHunk, in diff: FileDiff) {
        let allowed = Set(hunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
        let selected = (selectedLines[diff.file.path] ?? []).intersection(allowed)
        if !selected.isEmpty { apply(hunk, diff: diff, selected: selected) }
    }

    func apply(_ hunk: DiffHunk, diff: FileDiff, selected: Set<Int>?, succeeded: (() -> Void)? = nil) {
        guard let repository, diff.isPartialSupported else { return }
        let title = diff.area == .working ? "暂存\(selected == nil ? "整块" : "选定行")" : "取消\(selected == nil ? "整块" : "选定行")暂存"
        let path = diff.file.path
        mutateUndoable("\(title) · \(path)", capture: { try await repository.captureIndex([path]) }, succeeded: succeeded) {
            try await repository.apply(diff: diff, hunkID: hunk.id, selectedLineIDs: selected); return "\(path)\n\(hunk.header)"
        }
    }

    /// Loads both areas for every changed file, publishing as it goes so a large change set shows its first files quickly.
    func loadAllChanges() async {
        guard repository != nil, let root = repositoryURL, let files = snapshot?.files else { return }
        let request = UUID()
        let previous = Dictionary(allChanges.map { ($0.allChangesKey, $0.rawPatch) }, uniquingKeysWith: { first, _ in first })
        allChangesRequest = request
        allChangesLoading = true
        defer { if allChangesRequest == request { allChangesLoading = false } }
        let wanted = files.filter(\.hasStaged).map { ($0, ChangeArea.staged) } + files.filter(\.hasWorking).map { ($0, ChangeArea.working) }
        // Riskier files first (secrets, deleted tests, dependencies…), so 逐个验收 starts where a look matters most.
        let ranked = ReviewRiskRules.ordered(wanted) { ReviewRiskRules.pathRisk($0.0, area: $0.1).level }
        let limited = Array(ranked.prefix(Self.allChangesFileLimit))
        var results: [FileDiff] = []
        var failed = 0
        for (index, item) in limited.enumerated() {
            do { results.append(try await displayDiff(item.0, area: item.1)) }
            catch { failed += 1 }
            guard allChangesRequest == request, repositoryURL == root else { return }
            if index == 7 || index % 32 == 31 { allChanges = results }
        }
        // The diffs add what paths cannot show (a key in an added line, a test losing lines); equal risk keeps its place.
        allChanges = ReviewRiskRules.ordered(results) { ReviewRiskRules.assess($0).level }
        // Selections only survive while their file's diff is unchanged; line IDs of a new diff mean different lines.
        let unchanged = Set(results.filter { previous[$0.allChangesKey] == $0.rawPatch }.map(\.allChangesKey))
        allChangesSelection = allChangesSelection.filter { unchanged.contains($0.key) && !$0.value.isEmpty }
        var notes: [String] = []
        if wanted.count > limited.count { notes.append("只显示前 \(limited.count) 个文件差异，共 \(wanted.count) 个；其余请在「差异」里按文件查看。") }
        if failed > 0 { notes.append("\(failed) 个文件在读取时发生变化或读取失败，刷新后会重新读取。") }
        allChangesNotice = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    func toggleAllChangesLine(_ id: Int, in diff: FileDiff) {
        guard !busy, diff.isPartialSupported else { return }
        let key = diff.allChangesKey
        if allChangesSelection[key, default: []].contains(id) { allChangesSelection[key]?.remove(id) }
        else { allChangesSelection[key, default: []].insert(id) }
    }

    func clearAllChangesSelection() { allChangesSelection = [:] }

    /// Selected changed lines of one hunk on the all-changes page.
    func allChangesSelected(in hunk: DiffHunk, of diff: FileDiff) -> Set<Int> {
        let allowed = Set(hunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
        return (allChangesSelection[diff.allChangesKey] ?? []).intersection(allowed)
    }

    func applyAllChangesSelection(_ hunk: DiffHunk, in diff: FileDiff) {
        let selected = allChangesSelected(in: hunk, of: diff)
        if !selected.isEmpty { apply(hunk, diff: diff, selected: selected) }
    }
}
