import Foundation

extension EditorWorkspace {
    /// Uses the live buffer when open, preserving existing drafts and the normal disk-conflict checks.
    /// Returns true when the completion was saved, false when it joined an existing draft.
    /// `datesDone`: always write a ✅ date (随手记, which Git may not see); otherwise only where the file already has them.
    func completeIndexedTask(_ task: MarkdownIndex.Entry, today: String = TaskDates.key(Date()), datesDone: Bool = false) throws -> Bool {
        guard task.status.isOpen else { throw FolmiFailure(message: "这项待办已经不是没做完的了，请刷新列表后重试。") }
        return try rewriteIndexedTask(task) { line, text in
            var result = try Self.settingStatus(.done, in: line)
            // A ✅ date only where the file already writes them, so Folmi adds nothing to notes that never had one.
            if datesDone || text.contains("✅") { result = TaskDates.setting(.done, to: today, in: result) }
            return result
        }
    }

    /// Back to not done: the checkbox empties and its ✅ date goes.
    func reopenIndexedTask(_ task: MarkdownIndex.Entry) throws -> Bool {
        try rewriteIndexedTask(task) { line, _ in TaskDates.setting(.done, to: nil, in: try Self.settingStatus(.open, in: line)) }
    }

    /// Sets the task's due or planned date; nil takes it out.
    func setIndexedTaskDate(_ task: MarkdownIndex.Entry, _ kind: TaskDates.Kind, to value: String?) throws -> Bool {
        try rewriteIndexedTask(task) { line, _ in TaskDates.setting(kind, to: value, in: line) }
    }

    /// Puts back a task line exactly as it was before `rewriteIndexedTask`, for 撤销 on the task page.
    func restoreTaskLine(path: String, line number: Int, from current: String, to original: String) throws -> Bool {
        try rewriteLine(path: path, line: number) { line, _ in
            guard line == current else { throw FolmiFailure(message: "这一行已经又改过了，没有撤销。") }
            return original
        }
    }

    /// Rewrites the one line of `task`, after checking the file still has that task there (an index older than the
    /// file must never change another line). Saves when the file had no draft; otherwise the edit joins the draft.
    @discardableResult
    func rewriteIndexedTask(_ task: MarkdownIndex.Entry, _ transform: (String, String) throws -> String) throws -> Bool {
        try rewriteLine(path: task.path, line: task.line) { line, text in
            guard MarkdownIndex.parse(text, path: task.path).contains(where: { $0.line == task.line && $0.text == task.text && $0.kind == task.kind && $0.status == task.status }) else {
                throw FolmiFailure(message: "待办内容或行号已变化，请刷新列表后重试。现有草稿已保留。")
            }
            return try transform(line, text)
        }
    }

    /// Records the line's text before and after in `lastTaskLineEdit`, for undo.
    private func rewriteLine(path: String, line number: Int, _ transform: (String, String) throws -> String) throws -> Bool {
        let selection = selectedDocumentID
        defer { selectedDocumentID = selection }
        try open(path: path, asText: true)
        guard let document = documents.first(where: { $0.id == path }) else { throw FileEditorError.changedOnDisk }
        let lines = MarkdownReaderView.Coordinator.lineStarts(document.text)
        guard lines.indices.contains(number) else { throw FileEditorError.changedOnDisk }
        let source = document.text as NSString
        let start = lines[number]
        var end = number + 1 < lines.count ? lines[number + 1] : source.length
        // The line break stays as it is, \r\n included.
        while end > start, [10, 13].contains(source.character(at: end - 1)) { end -= 1 }
        let range = NSRange(location: start, length: end - start)
        let line = source.substring(with: range)
        let rewritten = try transform(line, document.text)
        guard rewritten != line else { return !document.isDirty }
        let wasClean = !document.isDirty
        updateText(id: path, text: source.replacingCharacters(in: range, with: rewritten))
        lastTaskLineEdit = TaskLineEdit(path: path, line: number, before: line, after: rewritten)
        if wasClean { try saveSelected() }
        return wasClean
    }

    /// `line` with its checkbox set to `status`.
    static func settingStatus(_ status: TaskStatus, in line: String) throws -> String {
        let regex = try NSRegularExpression(pattern: #"^([ \t]*(?:[-*+] |[0-9]+[.)] )\[)[ xX/-](\])"#)
        let source = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else {
            throw FolmiFailure(message: "找不到这项待办的复选框，请刷新列表后重试。")
        }
        return source.replacingCharacters(in: NSRange(location: match.range(at: 1).length, length: 1), with: String(status.mark))
    }
}

/// The last line the task page changed, so its notice can offer 撤销.
struct TaskLineEdit: Equatable {
    let path: String
    let line: Int
    let before: String
    let after: String
}

extension FolmiModel {
    func currentMarkdownTaskCount(for path: String) -> TaskCount? {
        if let document = editorWorkspace?.documents.first(where: { $0.path == path && $0.preview == nil }) {
            let entries = MarkdownIndex.parse(document.text, path: path)
            let tasks = entries.compactMap { entry -> Bool? in
                if case .task(let done) = entry.kind { return done }
                return nil
            }
            return TaskCount(done: tasks.filter { $0 }.count, total: tasks.count)
        }
        return markdownIndex?.files[path].map { TaskCount(done: $0.tasks.done, total: $0.tasks.total) }
    }

    /// Done tasks with a ✅ date in this project's Markdown, from the index (drafts are not read for these).
    var currentMarkdownDoneTasks: [MarkdownIndex.Entry] {
        (markdownIndex?.entries ?? []).filter { $0.status == .done && $0.dates.done != nil }
    }

    /// Open buffers override the disk index, so completed draft tasks disappear without saving unrelated edits.
    var currentMarkdownTasks: [MarkdownIndex.Entry] {
        var byPath = Dictionary(grouping: markdownIndex?.openTasks ?? [], by: \.path)
        for document in editorWorkspace?.documents ?? [] where MarkdownIndex.isMarkdown(document.path) && document.preview == nil {
            byPath[document.path] = MarkdownIndex.parse(document.text, path: document.path).filter {
                if case .task(false) = $0.kind { return true }
                return false
            }
        }
        return byPath.keys.sorted().flatMap { byPath[$0] ?? [] }
    }
}
