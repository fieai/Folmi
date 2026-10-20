import Foundation

/// One commit of the history view.
public struct CommitNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let parents: [String]
    public let shortID: String
    public let author: String
    public let email: String
    public let date: Date
    /// Ref names from `%D`: "HEAD -> main", "origin/main", "tag: v1".
    public let refs: [String]
    public let subject: String
    public init(id: String, parents: [String], shortID: String, author: String, email: String, date: Date, refs: [String], subject: String) {
        self.id = id; self.parents = parents; self.shortID = shortID; self.author = author; self.email = email
        self.date = date; self.refs = refs; self.subject = subject
    }
    public var isMerge: Bool { parents.count > 1 }

    /// Parses `git log -z --format=%H%x00%P%x00%h%x00%an%x00%ae%x00%at%x00%D%x00%s`.
    /// With `-z` each commit ends in NUL as well, so every record is eight fields.
    static func parse(_ text: String) -> [CommitNode] {
        let fields = text.components(separatedBy: "\0")
        var result: [CommitNode] = []
        var index = 0
        while index + 7 < fields.count {
            let id = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty {
                let refs = fields[index + 6].components(separatedBy: ", ").filter { !$0.isEmpty }
                result.append(CommitNode(
                    id: id, parents: fields[index + 1].split(separator: " ").map(String.init), shortID: fields[index + 2],
                    author: fields[index + 3], email: fields[index + 4],
                    date: Date(timeIntervalSince1970: TimeInterval(fields[index + 5]) ?? 0), refs: refs, subject: fields[index + 7]))
            }
            index += 8
        }
        return result
    }
}

/// Lanes for drawing history as a graph. Each row is drawn on its own; a line runs from the top edge to the node
/// (`upper`) or from the node to the bottom edge, and pass-through lines cross the whole row, so stacked rows join up.
public struct CommitGraphRow: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// Lane at the start and end of the half row (top→middle or middle→bottom); equal for a straight line.
        public let from: Int
        public let to: Int
        public let color: Int
        public let half: Half
        public init(from: Int, to: Int, color: Int, half: Half) { self.from = from; self.to = to; self.color = color; self.half = half }
    }
    public enum Half: Equatable, Sendable { case upper, lower, full }
    public let lane: Int
    public let color: Int
    public let lines: [Line]
    /// Lanes in use on this row, for the column width.
    public let width: Int
}

public enum CommitGraph {
    /// Lanes stay where they are while in use and a freed lane is reused, so branches do not shift sideways.
    public static func layout(_ commits: [CommitNode]) -> [CommitGraphRow] {
        var lanes: [String?] = []          // the commit each lane is heading for
        var colors: [Int] = []
        var nextColor = 0
        func allocate(_ id: String, preferAfter: Int) -> Int {
            let slot = lanes.indices.first { $0 > preferAfter && lanes[$0] == nil } ?? lanes.indices.first { lanes[$0] == nil }
            if let slot { lanes[slot] = id; colors[slot] = nextColor; nextColor += 1; return slot }
            lanes.append(id); colors.append(nextColor); nextColor += 1
            return lanes.count - 1
        }

        var rows: [CommitGraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            var lines: [CommitGraphRow.Line] = []
            let before = lanes
            let incoming = lanes.indices.filter { lanes[$0] == commit.id }
            // A branch tip nobody pointed at yet gets a lane of its own and no line from above.
            let lane = incoming.first ?? allocate(commit.id, preferAfter: -1)
            let color = colors[lane]
            // Upper half: lanes arriving at this commit bend into it.
            for index in incoming { lines.append(.init(from: index, to: lane, color: colors[index], half: .upper)) }
            for index in incoming where index != lane { lanes[index] = nil }

            // Lower half: the first parent continues this lane; other parents join an existing lane or open one.
            if let first = commit.parents.first {
                lanes[lane] = first
                lines.append(.init(from: lane, to: lane, color: color, half: .lower))
            } else {
                lanes[lane] = nil
            }
            for parent in commit.parents.dropFirst() {
                if let existing = lanes.indices.first(where: { lanes[$0] == parent && $0 != lane }) {
                    lines.append(.init(from: lane, to: existing, color: colors[existing], half: .lower))
                } else {
                    let slot = allocate(parent, preferAfter: lane)
                    lines.append(.init(from: lane, to: slot, color: colors[slot], half: .lower))
                }
            }
            // Lanes heading elsewhere pass straight through.
            for index in before.indices where before[index] != nil && before[index] != commit.id && lanes[index] == before[index] {
                lines.append(.init(from: index, to: index, color: colors[index], half: .full))
            }
            let used = max(lanes.lastIndex { $0 != nil }.map { $0 + 1 } ?? 0,
                           before.lastIndex { $0 != nil }.map { $0 + 1 } ?? 0, lane + 1)
            rows.append(CommitGraphRow(lane: lane, color: color, lines: lines, width: used))
            while lanes.last == .some(nil) { lanes.removeLast(); colors.removeLast() }
        }
        return rows
    }
}

/// A file changed by a commit, compared with its first parent.
public struct CommitFileChange: Identifiable, Hashable, Sendable {
    public let path: String
    /// A, M, D, T…
    public let status: String
    public var id: String { path }
    public init(path: String, status: String) { self.path = path; self.status = status }
}

/// A commit's full message and changed files.
public struct CommitDetail: Identifiable, Sendable, Equatable {
    public let id: String
    public let message: String
    public let committer: String
    public let committerDate: Date
    public let files: [CommitFileChange]
    public init(id: String, message: String, committer: String, committerDate: Date, files: [CommitFileChange]) {
        self.id = id; self.message = message; self.committer = committer; self.committerDate = committerDate; self.files = files
    }
}
