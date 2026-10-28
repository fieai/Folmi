import AppKit
import Foundation
import FolmiCore

/// One task on the 待办 page, with the project it lives in: the page lists the notes of every project at once.
struct ProjectTask: Identifiable, Equatable, Sendable {
    let root: String
    let project: String
    let entry: MarkdownIndex.Entry
    var id: String { root + "\0" + entry.id }
}

/// One 随手记 file, for the calendar: the day and time it was written and its first line.
struct IdeaNote: Identifiable, Equatable, Sendable {
    let root: String
    let project: String
    let path: String
    /// `yyyy-MM-dd` and `HH:mm`, from the file's name (IdeaStore names notes by when they were started), else from
    /// when the file was created.
    let day: String
    let time: String
    let title: String
    var id: String { root + "\0" + path }
}

/// What the 待办 page reads from every project's ideas/ folder (IdeaStore), off the main thread: the open tasks, the
/// done ones that carry a ✅ date (for 这周做完的), and the notes themselves (for the calendar). The notes are few and
/// small, so each read goes through them all; nothing is cached between reads.
enum IdeaTasks {
    static let maximumFilesPerProject = 2_000

    static func read(projects: [(root: String, name: String)]) -> [ProjectTask] { readAll(projects: projects).tasks }

    static func readAll(projects: [(root: String, name: String)]) -> (tasks: [ProjectTask], notes: [IdeaNote]) {
        var tasks: [ProjectTask] = []
        var notes: [IdeaNote] = []
        for project in projects where !Task.isCancelled {
            let root = URL(fileURLWithPath: project.root)
            // A linked worktree's .git is a file; its notes are its main checkout's, listed there.
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path, isDirectory: &isDirectory), !isDirectory.boolValue { continue }
            for path in notePaths(in: root) {
                let url = root.appendingPathComponent(path)
                guard let data = try? Data(contentsOf: url), data.count <= MarkdownIndex.maximumBytes,
                      let decoded = UTF8Text.decode(data) else { continue }
                let text = String(decoded.drop { $0 == "\u{FEFF}" })
                tasks += listedTasks(text, path: path).map { ProjectTask(root: project.root, project: project.name, entry: $0) }
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                if let when = written(path, created: created) {
                    notes.append(IdeaNote(root: project.root, project: project.name, path: path, day: when.day, time: when.time, title: title(text)))
                }
            }
        }
        return (tasks, notes)
    }

    /// When a note was written: from IdeaStore's `20261025-180300` name, else the file's creation date.
    static func written(_ path: String, created: Date?, calendar: Calendar = .current) -> (day: String, time: String)? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let digits = Array(name.prefix(15))
        if digits.count == 15, digits[8] == "-", digits.enumerated().allSatisfy({ $0.offset == 8 || $0.element.isNumber }) {
            let d = String(digits)
            return ("\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.dropFirst(6).prefix(2))", "\(d.dropFirst(9).prefix(2)):\(d.dropFirst(11).prefix(2))")
        }
        guard let created else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: created)
        return (TaskDates.key(created, calendar: calendar), String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))
    }

    /// The note's first line with text, without its heading, list or task marks and dates.
    static func title(_ text: String) -> String {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = TaskDates.split(MarkdownCommands.strippedBlockPrefix(String(raw)).text).title
            if !line.isEmpty { return String(line.prefix(80)) }
        }
        return "（空白）"
    }

    static func openTasks(_ text: String, path: String) -> [MarkdownIndex.Entry] {
        MarkdownIndex.parse(text, path: path).filter { $0.kind == .task(done: false) }
    }

    /// Open tasks, and done ones with the day they were done.
    static func listedTasks(_ text: String, path: String) -> [MarkdownIndex.Entry] {
        MarkdownIndex.parse(text, path: path).filter(\.isListed)
    }

    static func isNote(_ path: String) -> Bool { path.hasPrefix(IdeaStore.folder + "/") && MarkdownIndex.isMarkdown(path) }

    /// Markdown files under ideas/, relative to `root`, oldest name first (the names are their dates).
    static func notePaths(in root: URL) -> [String] {
        let folder = root.appendingPathComponent(IdeaStore.folder, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var paths: [String] = []
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard paths.count < maximumFilesPerProject else { break }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix), MarkdownIndex.isMarkdown(path),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            paths.append(String(path.dropFirst(prefix.count)))
        }
        return paths.sorted()
    }

    /// 「10月25日的随手记」 for a note named by IdeaStore (20261025-180300.md), else the file's name.
    static func noteTitle(_ path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let digits = name.prefix(8)
        guard isNote(path), digits.count == 8, digits.allSatisfy(\.isNumber),
              let month = Int(digits.dropFirst(4).prefix(2)), let day = Int(digits.suffix(2)) else { return (path as NSString).lastPathComponent }
        return "\(month)月\(day)日的随手记"
    }
}

extension FolmiModel {
    /// Re-reads the notes of every project in the background; the page shows the last read until this one ends.
    func loadIdeaTasks() {
        let projects = projects.map { (root: $0.rootPath, name: $0.name) }
        ideaTasksTask?.cancel()
        ideaTasksTask = Task { [weak self] in
            let read = await Task.detached(priority: .utility) { IdeaTasks.readAll(projects: projects) }.value
            guard let self, !Task.isCancelled else { return }
            if self.ideaTasks != read.tasks { self.ideaTasks = read.tasks }
            if self.ideaNotes != read.notes { self.ideaNotes = read.notes }
        }
    }

    /// The notes' open tasks, with the open project's unsaved notes read from their drafts instead of the disk.
    var currentIdeaTasks: [ProjectTask]? {
        guard var tasks = ideaTasks else { return nil }
        guard let root = repositoryURL?.path, let editor = editorWorkspace else { return tasks }
        let name = projects.first { $0.rootPath == root }?.name ?? (root as NSString).lastPathComponent
        for document in editor.documents where IdeaTasks.isNote(document.path) && document.preview == nil && document.isDirty {
            tasks.removeAll { $0.root == root && $0.entry.path == document.path }
            tasks += IdeaTasks.listedTasks(document.text, path: document.path).map { ProjectTask(root: root, project: name, entry: $0) }
        }
        return tasks
    }

    /// Opens a task's line, switching projects first when it lives in another one.
    func openTask(_ task: ProjectTask) {
        let line = PaletteItem(id: "line:" + task.entry.id, kind: .task, title: task.entry.text, subtitle: task.entry.path,
                               action: .openLine(task.entry.path, task.entry.line))
        openInProject(task.root) { $0.pickPaletteItem(line) }
    }

    /// Opens a note in the reading view, switching projects first when it lives in another one.
    func openNote(_ note: IdeaNote) {
        openInProject(note.root) { model in
            guard let editor = model.editorWorkspace else { return }
            do {
                try editor.open(path: note.path)
                editor.markdownReading = true
                model.content = .editor
                model.focusPane(.editor)
            } catch { model.report(error, title: "打开随手记失败") }
        }
    }

    /// 交给 Codex on a 待办: the line, with the note it is in for context, into the agent's composer of its project.
    func handTaskToAgent(_ task: ProjectTask) {
        let entry = task.entry
        let note = (try? String(contentsOf: URL(fileURLWithPath: task.root).appendingPathComponent(entry.path), encoding: .utf8)) ?? ""
        let text = "待办（\(entry.path) 第 \(entry.line + 1) 行）：\(entry.text)"
            + (note.isEmpty ? "" : "\n\n它所在的笔记：\n" + String(note.prefix(8_000)))
        let uri = URL(fileURLWithPath: task.root).appendingPathComponent(entry.path).absoluteString + "#L\(entry.line + 1)"
        openInProject(task.root) { $0.attachToAgent([AgentContext(title: "待办：\(entry.text.prefix(30))", text: text, uri: uri)]) }
    }

    /// 交给 Codex on a 随手记: the whole note.
    func handNoteToAgent(_ note: IdeaNote) {
        let file = URL(fileURLWithPath: note.root).appendingPathComponent(note.path)
        guard let text = try? String(contentsOf: file, encoding: .utf8), TerminalSnippet.plain(text) != nil else { NSSound.beep(); return }
        openInProject(note.root) {
            $0.attachToAgent([AgentContext(title: "随手记 \(note.path)", text: String(text.prefix(40_000)), uri: file.absoluteString)])
        }
    }

    private func openInProject(_ root: String, _ open: @escaping @MainActor (FolmiModel) -> Void) {
        if root == repositoryURL?.path { open(self); return }
        switchProject(root)
        // switchProject starts nothing while busy or Git is unavailable; the action waits only for a switch under way.
        if busy { pendingProjectOpen = (root, open) }
    }

    /// After a project switch from the 待办 page, what it was opened for.
    func openPendingTaskLine() {
        guard let pending = pendingProjectOpen else { return }
        pendingProjectOpen = nil
        if pending.root == repositoryURL?.path { pending.open(self) }
    }
}
