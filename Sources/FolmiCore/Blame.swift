import Foundation

/// Who last changed each line of a file as HEAD has it.
public struct FileBlame: Sendable, Equatable {
    public struct Commit: Sendable, Equatable {
        public let id: String
        public let author: String
        public let email: String
        public let date: Date
        public let subject: String
        public init(id: String, author: String, email: String, date: Date, subject: String) {
            self.id = id; self.author = author; self.email = email; self.date = date; self.subject = subject
        }
        public var shortID: String { String(id.prefix(7)) }
    }
    public let path: String
    /// The HEAD commit this was computed for.
    public let head: String
    /// HEAD's text, normalized to LF newlines, so the editor buffer can be mapped onto it.
    public let text: String
    /// For each HEAD line (0-based), an index into `commits`.
    public let lineCommits: [Int]
    public let commits: [Commit]
    /// The user's author email, to show their own lines as 你.
    public let userEmail: String?
    public init(path: String, head: String, text: String, lineCommits: [Int], commits: [Commit], userEmail: String?) {
        self.path = path; self.head = head; self.text = text; self.lineCommits = lineCommits; self.commits = commits; self.userEmail = userEmail
    }

    public func commit(atHeadLine line: Int) -> Commit? {
        line >= 0 && line < lineCommits.count ? commits[lineCommits[line]] : nil
    }

    /// Parses `git blame --porcelain` output.
    static func parse(_ output: Data, path: String, head: String, userEmail: String?) -> FileBlame? {
        var commits: [Commit] = [], indexByID: [String: Int] = [:]
        var lineCommits: [Int] = [], lines: [String] = []
        var pending: [String: String] = [:]
        var current: String?
        var finalLine = 0
        for raw in output.split(separator: 10, omittingEmptySubsequences: false) {
            if raw.first == 9 {
                // The line's content ends the entry.
                guard let id = current, let content = UTF8Text.decode(Data(raw.dropFirst())) else { return nil }
                if indexByID[id] == nil {
                    indexByID[id] = commits.count
                    let mail = pending["author-mail"] ?? ""
                    commits.append(Commit(id: id, author: pending["author"] ?? "", email: mail.trimmingCharacters(in: CharacterSet(charactersIn: "<>")),
                                          date: Date(timeIntervalSince1970: TimeInterval(pending["author-time"] ?? "") ?? 0),
                                          subject: pending["summary"] ?? ""))
                }
                guard finalLine == lineCommits.count else { return nil }
                lineCommits.append(indexByID[id]!)
                lines.append(content.hasSuffix("\r") ? String(content.dropLast()) : content)
                current = nil; pending = [:]
                continue
            }
            let line = String(decoding: raw, as: UTF8.self)
            if current == nil {
                let fields = line.split(separator: " ")
                guard fields.count >= 3, fields[0].count >= 40, fields[0].allSatisfy(\.isHexDigit), let final = Int(fields[2]) else { continue }
                current = String(fields[0]); finalLine = final - 1
            } else if let space = line.firstIndex(of: " ") {
                pending[String(line[..<space])] = String(line[line.index(after: space)...])
            }
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return FileBlame(path: path, head: head, text: text, lineCommits: lineCommits, commits: commits, userEmail: userEmail)
    }
}

extension GitRepository {
    /// Line authors of the file in HEAD; nil on an unborn branch or when HEAD has no such file.
    /// Throws when Git cannot answer (too slow, not text), so a failure is never shown as a new file.
    public func blame(path: String) async throws -> FileBlame? {
        let git = try runner()
        let headResult = try git.run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], allowFailure: true)
        guard headResult.status == 0 else { return nil }
        let head = headResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try git.run(["cat-file", "-e", "\(head):\(path)"], allowFailure: true).status == 0 else { return nil }
        var arguments = ["blame", "--porcelain"]
        // Formatting-only commits listed by the project are skipped, as GitHub does.
        if FileManager.default.fileExists(atPath: git.directory.appendingPathComponent(".git-blame-ignore-revs").path) {
            arguments += ["--ignore-revs-file", ".git-blame-ignore-revs"]
        }
        arguments += [head, "--", path]
        let result = try git.run(arguments, timeout: 30, stdoutLimit: 64 * 1_024 * 1_024)
        // The identity new commits get (config or GIT_AUTHOR_EMAIL), so the user's own lines read 你.
        let ident = try git.run(["var", "GIT_AUTHOR_IDENT"], allowFailure: true).text
        let email = ident.firstIndex(of: "<").flatMap { open in
            ident[open...].firstIndex(of: ">").map { String(ident[ident.index(after: open)..<$0]) }
        } ?? ""
        guard !result.stdout.contains(0),
              let blame = FileBlame.parse(result.stdout, path: path, head: head, userEmail: email.isEmpty ? nil : email) else {
            throw FolmiError.unsupported("这个文件不是文本，读不出每行的作者。")
        }
        return blame
    }

    /// Commits that changed lines `first...last` (1-based, as HEAD has them), newest first.
    public func lineHistory(path: String, first: Int, last: Int, limit: Int = 20) async throws -> [FileBlame.Commit] {
        let git = try runner()
        guard first >= 1, last >= first else { return [] }
        let text = try git.run(["log", "-s", "-n", String(limit), "-L\(first),\(last):\(path)",
                                "--format=%x01%H%x00%an%x00%ae%x00%at%x00%s", "HEAD"], allowFailure: true, timeout: 30).text
        return text.components(separatedBy: "\u{1}").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
            guard fields.count >= 5, !fields[0].isEmpty else { return nil }
            return FileBlame.Commit(id: fields[0], author: fields[1], email: fields[2],
                                    date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0), subject: fields[4])
        }
    }
}
