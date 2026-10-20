import Foundation

extension EditorWorkspace {
    /// Uses the live buffer when open, preserving existing drafts and the normal disk-conflict checks.
    /// Returns true when the completion was saved, false when it joined an existing draft.
    func completeIndexedTask(_ task: MarkdownIndex.Entry) throws -> Bool {
        let selection = selectedDocumentID
        defer { selectedDocumentID = selection }
        try open(path: task.path, asText: true)
        guard let document = documents.first(where: { $0.id == task.path }),
              MarkdownIndex.parse(document.text, path: task.path).contains(task),
              case .task(false) = task.kind else {
            throw FolmiFailure(message: "待办内容或行号已变化，请刷新列表后重试。现有草稿已保留。")
        }
        let lines = MarkdownReaderView.Coordinator.lineStarts(document.text)
        guard lines.indices.contains(task.line) else { throw FileEditorError.changedOnDisk }
        let source = document.text as NSString
        let start = lines[task.line]
        let end = task.line + 1 < lines.count ? lines[task.line + 1] : source.length
        let line = source.substring(with: NSRange(location: start, length: end - start)) as NSString
        let regex = try NSRegularExpression(pattern: #"^ *(?:[-*+] |[0-9]+[.)] )\[ \]"#)
        guard let prefix = regex.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else {
            throw FolmiFailure(message: "找不到这项待办的复选框，请刷新列表后重试。")
        }
        try toggleTask(at: start + prefix.range.location + prefix.range.length - 2, in: task.path)
        return !document.isDirty
    }
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
