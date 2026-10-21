import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// Saving preferences and each project's session (tabs, review progress, terminal folders), and quitting.
extension FolmiModel {
    /// A project's settings as last saved, session state included (open tabs, review progress, terminal folders).
    /// `projects` itself only carries what the window shows (names, profiles), so saving the session every half
    /// second does not re-render the window.
    func savedProject(_ path: String) -> ProjectPreferences? {
        preferences.projects.first { $0.rootPath == path } ?? projects.first { $0.rootPath == path }
    }

    func captureProjectState() {
        if let snapshot, snapshot.fingerprint != savedSnapshotFingerprint {
            savedSnapshotFingerprint = snapshot.fingerprint
            SnapshotCache.save(snapshot)
        }
        var saved = projects
        for index in saved.indices {
            let path = saved[index].rootPath
            if let previous = preferences.projects.first(where: { $0.rootPath == path }) {
                saved[index].draftMessage = previous.draftMessage; saved[index].amendLast = previous.amendLast
                saved[index].selectedProfileID = previous.selectedProfileID; saved[index].lastArea = previous.lastArea
                saved[index].reviewedLines = previous.reviewedLines; saved[index].lastContent = previous.lastContent
                saved[index].selectedChangePath = previous.selectedChangePath
                saved[index].editorTabs = previous.editorTabs; saved[index].selectedEditorPath = previous.selectedEditorPath
                saved[index].terminalTabs = previous.terminalTabs; saved[index].terminalDirectories = previous.terminalDirectories
                saved[index].editorColumns = previous.editorColumns; saved[index].terminalColumns = previous.terminalColumns
            }
            if path == repositoryURL?.path {
                saved[index].draftMessage = draftMessage; saved[index].amendLast = amendLast
                saved[index].selectedProfileID = selectedProfileID; saved[index].lastArea = area.rawValue
                saved[index].reviewedLines = reviewLedger.order
                saved[index].lastContent = content.rawValue
                saved[index].selectedChangePath = selectedFileID
            }
            if let editor = editors[path] {
                saved[index].editorTabs = editor.sessionState()
                saved[index].selectedEditorPath = editor.selectedDocumentID
                saved[index].editorColumns = editor.columns.isSplit ? editor.columns : nil
            }
            saved[index].reviewComments = reviewComments.filter { $0.projectPath == path }
            if let tabs = terminals[path], !tabs.isEmpty {
                saved[index].terminalTabs = tabs.map(\.name)
                // Both sides resolved: the shell reports /private/var/… while a standardized path may drop /private.
                let base = SnapshotCache.key(path)
                saved[index].terminalDirectories = tabs.map { tab in
                    guard let directory = tab.currentDirectory?.resolvingSymlinksInPath().path, directory.hasPrefix(base + "/") else { return "" }
                    return String(directory.dropFirst(base.count + 1))
                }
                let places = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id.uuidString, String($0)) })
                saved[index].terminalColumns = terminalColumns[path].flatMap { $0.isSplit ? $0.mapTabs { places[$0] } : nil }
            } else if terminalTabsCleared.contains(path) {
                saved[index].terminalTabs = []; saved[index].terminalDirectories = []; saved[index].terminalColumns = nil
            }
        }
        preferences.projects = saved
        preferences.appearance = appearance
        preferences.theme = theme
        preferences.glassSurfaces = glassSurfaces
        preferences.editorLineBlame = editorLineBlame
        preferences.markdownDiffRendered = markdownDiffRendered
        preferences.unifiedDiff = unifiedDiff
        preferences.foldWhitespace = foldWhitespace
        preferences.companionMotion = companionMotion
        preferences.editorFontSize = editorFontSize
        preferences.markdownFontFamily = markdownFontFamily
        preferences.markdownFontSize = markdownFontSize
        preferences.markdownReadingWidth = markdownReadingWidth
        if let editor = editorWorkspace {
            preferences.editorWrapLines = editor.presentation.wrapLines
            preferences.markdownReading = editor.markdownReading
            preferences.markdownOutline = editor.showsOutline
            preferences.markdownOutlineWidth = editor.outlineWidth
        }
        preferences.selectedProjectPath = repositoryURL?.path ?? preferences.selectedProjectPath; preferences.showTerminal = showTerminal
        preferences.paneLayout = paneLayout
    }

    /// Saves half a second after the last change. Editor caret and scroll changes call this on every event, so it
    /// only moves a deadline; one sleeping task waits for it instead of a task being made and cancelled per event.
    func scheduleSave() {
        guard !restoring else { return }
        saveDeadline = ContinuousClock.now + .milliseconds(500)
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            while let deadline = self?.saveDeadline, ContinuousClock.now < deadline {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.saveDeadline = nil
            // Validating, encoding and writing the file took 10–15 ms; it now happens off the main thread so an
            // autosave never lands on top of the next file switch.
            self.captureProjectState()
            let preferences = self.preferences, store = self.store
            Self.preferenceWrites.async { [weak self] in
                do {
                    try store.save(preferences)
                    DispatchQueue.main.async {
                        if let self, self.preferencesStatus != "已保存个人配置" { self.preferencesStatus = "已保存个人配置" }
                    }
                } catch {
                    DispatchQueue.main.async { self?.report(error, title: "保存个人配置失败") }
                }
            }
        }
    }

    func savePreferencesNow() throws {
        saveTask?.cancel(); saveTask = nil; saveDeadline = nil
        captureProjectState()
        let preferences = self.preferences, store = self.store
        try Self.preferenceWrites.sync { try store.save(preferences) }
        // Publishing the same text would still re-render the whole window after every autosave.
        if preferencesStatus != "已保存个人配置" { preferencesStatus = "已保存个人配置" }
    }

    func prepareToQuit() -> Bool {
        if busy { let alert = NSAlert(); alert.messageText = "操作正在执行，请完成后再退出。"; alert.runModal(); return false }
        if editors.values.contains(where: \.hasUnsavedChanges) {
            let alert = NSAlert(); alert.messageText = "有文件尚未保存"; alert.informativeText = "包含其他项目中打开的编辑。"
            alert.addButton(withTitle: "保存全部并退出"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "放弃编辑并退出")
            let choice = alert.runModal()
            if choice == .alertSecondButtonReturn { return false }
            if choice == .alertFirstButtonReturn {
                do { for editor in editors.values { try editor.saveAll() } } catch { report(error, title: "保存文件失败"); return false }
            }
        }
        do { try savePreferencesNow() } catch { report(error, title: "保存个人配置失败"); return false }
        cancelProjectSearch()
        terminals.values.joined().forEach { $0.stop() }; return true
    }
}
