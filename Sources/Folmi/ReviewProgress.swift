import CryptoKit
import Foundation
import FolmiCore

/// Review progress, like read / unread mail. A changed line is "seen" by its content (file, added or removed, text,
/// and which repeat of that text it is), not by line number, so it stays seen when other edits move it and when it
/// moves from the work tree to the index. A hunk is seen when all its changed lines are; an AI edit that touches a
/// seen hunk brings back only the hunk it changed.
///
/// Repeats are counted across both areas of a file, staged lines first: an empty line added in the index and
/// another in the work tree are repeat 0 and 1, never both 0, so seeing one does not mark the other, and staging
/// the second keeps both keys (the index then holds repeats 0 and 1).
enum ReviewProgress {
    /// Most recent keys kept per project.
    static let limit = 8_000

    /// One key per added or removed line of the diff, by line ID. For a work-tree diff, `staged` is the same file's
    /// HEAD → index diff, whose lines come first in the repeat count.
    static func lineKeys(_ diff: FileDiff, staged: FileDiff? = nil) -> [Int: String] {
        var seen: [String: Int] = [:], keys: [Int: String] = [:]
        func base(_ line: DiffLine) -> String { diff.file.path + "\0" + (line.kind == .addition ? "+" : "-") + line.text }
        if diff.area == .working, let staged, staged.area == .staged, staged.file.path == diff.file.path {
            for line in staged.hunks.lazy.flatMap(\.lines) where line.kind == .addition || line.kind == .deletion { seen[base(line), default: 0] += 1 }
        }
        for line in diff.hunks.lazy.flatMap(\.lines) where line.kind == .addition || line.kind == .deletion {
            let base = base(line)
            let repeatIndex = seen[base, default: 0]
            seen[base] = repeatIndex + 1
            keys[line.id] = digest(base + "\0\(repeatIndex)")
        }
        return keys
    }
    static func hunkKeys(_ hunk: DiffHunk, in keys: [Int: String]) -> [String] { hunk.lines.compactMap { keys[$0.id] } }
    /// The keys a new file's lines get once it is staged, where HEAD → index shows every line as added. In the work
    /// tree the file has no hunks, so without these the hunk it becomes would come back as unseen.
    static func stagedKeys(newFile path: String, text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var seen: [String: Int] = [:]
        return lines.map { line in
            let base = path + "\0+" + line
            let repeatIndex = seen[base, default: 0]
            seen[base] = repeatIndex + 1
            return digest(base + "\0\(repeatIndex)")
        }
    }
    /// A diff without hunks (a new file, a binary or mode change) is seen as a whole, by its content.
    static func fileKey(_ diff: FileDiff) -> String? {
        guard diff.hunks.isEmpty else { return nil }
        return digest("file\0" + diff.file.path + "\0" + diff.file.indexCode + diff.file.worktreeCode + "\0" + diff.rawPatch)
    }

    /// The hunks of a staged patch (`git diff --cached`) with their line keys, the same keys the staged diff's lines get
    /// in the review (repeats counted per file in patch order), so what is staged can be checked against what was seen
    /// without loading every diff. Binary files and files without hunks are left out.
    static func stagedHunks(patch: String) -> [(path: String, keys: [String])] {
        var result: [(path: String, keys: [String])] = []
        var path = "", oldPath = "", inHunk = false
        var seen: [String: Int] = [:]
        for raw in patch.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git ") { inHunk = false; path = ""; oldPath = ""; seen = [:]; continue }
            if !inHunk {
                if raw.hasPrefix("--- ") { oldPath = raw.hasPrefix("--- a/") ? String(raw.dropFirst(6)) : ""; continue }
                if raw.hasPrefix("+++ ") { path = raw.hasPrefix("+++ b/") ? String(raw.dropFirst(6)) : oldPath; continue }
            }
            if raw.hasPrefix("@@") { inHunk = true; result.append((path, [])); continue }
            guard inHunk, let sign = raw.first, sign == "+" || sign == "-", !result.isEmpty else { continue }
            let base = path + "\0" + String(sign) + String(raw.dropFirst())
            let repeatIndex = seen[base, default: 0]
            seen[base] = repeatIndex + 1
            result[result.count - 1].keys.append(digest(base + "\0\(repeatIndex)"))
        }
        return result.filter { !$0.keys.isEmpty }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Seen-line keys of one project in the order they were marked, so the oldest can be dropped.
struct ReviewLedger: Equatable {
    private(set) var order: [String] = []
    private(set) var keys: Set<String> = []
    init(_ saved: [String] = []) { for key in saved { insert(key) } }

    func contains(_ key: String) -> Bool { keys.contains(key) }
    func containsAll(_ list: [String]) -> Bool { !list.isEmpty && list.allSatisfy(keys.contains) }

    mutating func insert(_ key: String) {
        guard keys.insert(key).inserted else { return }
        order.append(key)
        if order.count > ReviewProgress.limit {
            let drop = order.count - ReviewProgress.limit
            order.prefix(drop).forEach { keys.remove($0) }
            order.removeFirst(drop)
        }
    }
    mutating func remove(_ list: [String]) {
        let removing = Set(list).intersection(keys)
        guard !removing.isEmpty else { return }
        keys.subtract(removing)
        order.removeAll { removing.contains($0) }
    }
}

/// Counts for the review header and the "all done" state.
struct ReviewTally: Equatable {
    var hunks = 0
    var seen = 0
    var remaining: Int { hunks - seen }

    static func make(_ diffs: [FileDiff], ledger: ReviewLedger,
                     keys lineKeys: (FileDiff, FileDiff?) -> [Int: String] = { ReviewProgress.lineKeys($0, staged: $1) }) -> ReviewTally {
        var tally = ReviewTally()
        let staged = Dictionary(diffs.filter { $0.area == .staged }.map { ($0.file.path, $0) }, uniquingKeysWith: { a, _ in a })
        for diff in diffs {
            if let key = ReviewProgress.fileKey(diff) {
                tally.hunks += 1
                if ledger.contains(key) { tally.seen += 1 }
                continue
            }
            let keys = lineKeys(diff, diff.area == .working ? staged[diff.file.path] : nil)
            for hunk in diff.hunks {
                let list = ReviewProgress.hunkKeys(hunk, in: keys)
                guard !list.isEmpty else { continue }
                tally.hunks += 1
                if ledger.containsAll(list) { tally.seen += 1 }
            }
        }
        return tally
    }
}
