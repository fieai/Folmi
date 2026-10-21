import Foundation
import FolmiCore

/// What the staged change should not carry into a commit, found before committing.
struct CommitCheck: Equatable {
    struct Finding: Equatable, Hashable {
        enum Kind: String { case secret, sensitiveFile, largeFile, conflict, debug }
        let kind: Kind
        let path: String
        let detail: String
        var blocking: Bool { kind == .secret || kind == .sensitiveFile || kind == .conflict }
        var label: String {
            switch kind {
            case .secret: return "疑似密钥"
            case .sensitiveFile: return "敏感文件"
            case .largeFile: return "大文件"
            case .conflict: return "冲突标记"
            case .debug: return "调试残留"
            }
        }
    }
    var findings: [Finding] = []
    /// Fingerprint of the snapshot the check ran on.
    var fingerprint = ""
    /// Every staged hunk with its line keys, to tell which of them were never seen (see `unreviewed`).
    var stagedHunks: [StagedHunk] = []
    struct StagedHunk: Equatable { let path: String; let keys: [String] }

    /// Staged hunks that went in without being looked at, per file. Worked out against the ledger as it is now, so
    /// accepting one on the review page clears it at once.
    func unreviewed(_ ledger: ReviewLedger) -> [String: Int] {
        var counts: [String: Int] = [:]
        for hunk in stagedHunks where !hunk.keys.allSatisfy(ledger.contains) { counts[hunk.path, default: 0] += 1 }
        return counts
    }
    var blocking: Bool { findings.contains(where: \.blocking) }

    static let largeBytes = 5 * 1024 * 1024
    private static let debugPatterns = [#"console\.log\("#, #"\bdebugger;?\s*$"#, #"\bdbg!\("#, #"pdb\.set_trace\(\)"#, #"\bbreakpoint\(\)"#,
                                        #"binding\.pry"#, #"\bvar_dump\("#, #"(?i)TODO:?\s*remove"#]
        .compactMap { try? NSRegularExpression(pattern: $0) }
    private static let conflict = try! NSRegularExpression(pattern: #"^(<{7}|={7}|>{7})( |$)"#)

    /// Looks at the added lines of a staged patch, file by file, plus file names and sizes.
    static func run(patch: String, stagedPaths: [String], sizes: [String: Int], fingerprint: String) -> CommitCheck {
        var check = CommitCheck(fingerprint: fingerprint)
        var seen = Set<Finding>()
        func add(_ finding: Finding) { if seen.insert(finding).inserted, check.findings.count < 12 { check.findings.append(finding) } }
        for path in stagedPaths where SecretScan.isSensitivePath(path) { add(Finding(kind: .sensitiveFile, path: path, detail: "通常不应提交")) }
        for (path, size) in sizes where size > largeBytes { add(Finding(kind: .largeFile, path: path, detail: "\(size / 1024 / 1024) MB")) }
        var path = ""
        var lineNumber = 0
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("+++ ") { path = line.hasPrefix("+++ b/") ? String(line.dropFirst(6)) : String(line.dropFirst(4)); continue }
            if line.hasPrefix("@@ ") {
                lineNumber = Int(line.split(separator: "+").dropFirst().first?.split(separator: ",").first?.split(separator: " ").first ?? "") ?? 0
                continue
            }
            if line.hasPrefix("+") {
                let added = String(line.dropFirst())
                let range = NSRange(added.startIndex..., in: added)
                if added.count < 4_000 {
                    if !SecretScan.findings(in: added).isEmpty { add(Finding(kind: .secret, path: path, detail: "第 \(lineNumber) 行")) }
                    if conflict.firstMatch(in: added, range: range) != nil { add(Finding(kind: .conflict, path: path, detail: "第 \(lineNumber) 行")) }
                    if debugPatterns.contains(where: { $0.firstMatch(in: added, range: range) != nil }) {
                        add(Finding(kind: .debug, path: path, detail: "第 \(lineNumber) 行：" + String(added.trimmingCharacters(in: .whitespaces).prefix(40))))
                    }
                }
                lineNumber += 1
            } else if line.hasPrefix(" ") { lineNumber += 1 }
        }
        return check
    }
}

extension FolmiModel {
    /// Re-checks what is staged after it changed; quick (one `git diff --cached`), off the main thread for the scan.
    func scheduleCommitCheck() {
        guard let repository, let snapshot, let root = repositoryURL else { return }
        let staged = snapshot.files.filter(\.hasStaged)
        guard !staged.isEmpty else { if commitCheck != nil { commitCheck = nil }; return }
        guard commitCheck?.fingerprint != snapshot.fingerprint else { return }
        let fingerprint = snapshot.fingerprint
        commitCheckTask?.cancel()
        commitCheckTask = Task { [weak self] in
            guard let check = try? await Self.checkStaged(repository, root: root, paths: staged.map(\.path), fingerprint: fingerprint) else { return }
            guard let self, !Task.isCancelled, self.snapshot?.fingerprint == fingerprint else { return }
            self.commitCheck = check
        }
    }

    /// The check of what is staged now, labelled with `fingerprint`, the snapshot it belongs to.
    static func checkStaged(_ repository: GitRepository, root: URL, paths: [String], fingerprint: String) async throws -> CommitCheck {
        let patch = try await repository.stagedPatch(limit: 2_000_000)
        let check = await Task.detached(priority: .userInitiated) { () -> CommitCheck in
            var sizes: [String: Int] = [:]
            for path in paths {
                if let size = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path))?[.size] as? NSNumber {
                    sizes[path] = size.intValue
                }
            }
            var check = CommitCheck.run(patch: patch.patch, stagedPaths: paths, sizes: sizes, fingerprint: fingerprint)
            check.stagedHunks = ReviewProgress.stagedHunks(patch: patch.patch).map { CommitCheck.StagedHunk(path: $0.path, keys: $0.keys) }
            return check
        }.value
        return check
    }

    /// Commit pressed before the check of exactly what is staged finished: wait for it, then press again for the user,
    /// so a found secret still asks first. A check that cannot run does not let the commit through.
    func commitAfterCheck(_ state: RepositorySnapshot) {
        guard let repository, !commitCheckWaiting else { return }
        commitCheckWaiting = true
        let paths = state.files.filter(\.hasStaged).map(\.path)
        Task { [weak self] in
            let result: Result<CommitCheck, Error>
            do { result = .success(try await Self.checkStaged(repository, root: state.root, paths: paths, fingerprint: state.fingerprint)) }
            catch { result = .failure(error) }
            guard let self else { return }
            self.commitCheckWaiting = false
            switch result {
            case .failure(let error):
                self.errorMessage = "提交前检查没能完成，没有提交：\(error.localizedDescription)"
            case .success(let check):
                // Something changed while checking: the next press checks the new state.
                guard self.snapshot?.fingerprint == state.fingerprint else { return }
                self.commitCheck = check
                self.commit()
            }
        }
    }
}
