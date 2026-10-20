import Foundation

/// Myers line diff for editor gutter marks. Common prefix and suffix are trimmed first, so a few edits in a large
/// file stay cheap; past `maxEdits` the differing middle is reported as one change instead of searching further.
public enum LineDiff {
    public struct Change: Equatable, Sendable {
        /// Lines replaced in the old text (empty for a pure insertion).
        public let old: Range<Int>
        /// Lines that replace them in the new text (empty for a pure deletion).
        public let new: Range<Int>
        public init(old: Range<Int>, new: Range<Int>) { self.old = old; self.new = new }
        public var isInsertion: Bool { old.isEmpty }
        public var isDeletion: Bool { new.isEmpty }
    }

    public static func changes<T: Equatable>(old a: [T], new b: [T], maxEdits: Int = 1_000) -> [Change] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let n = a.count - prefix - suffix, m = b.count - prefix - suffix
        if n == 0 && m == 0 { return [] }
        let whole = [Change(old: prefix..<(prefix + n), new: prefix..<(prefix + m))]
        if n == 0 || m == 0 { return whole }

        let limit = min(n + m, maxEdits)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var finalD: Int?
        search: for d in 0...limit {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) ? v[k + 1 + offset] : v[k - 1 + offset] + 1
                var y = x - k
                while x < n, y < m, a[prefix + x] == b[prefix + y] { x += 1; y += 1 }
                v[k + offset] = x
                if x >= n && y >= m { finalD = d; break search }
            }
        }
        guard let finalD else { return whole }

        var deleted = [Bool](repeating: false, count: n), inserted = [Bool](repeating: false, count: m)
        var x = n, y = m
        for d in stride(from: finalD, through: 0, by: -1) {
            let v = trace[d], k = x - y
            let previousK = (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) ? k + 1 : k - 1
            let previousX = v[previousK + offset], previousY = previousX - previousK
            while x > previousX, y > previousY { x -= 1; y -= 1 }
            if d > 0 {
                if x == previousX { y -= 1; inserted[y] = true } else { x -= 1; deleted[x] = true }
            }
        }

        var result: [Change] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, !deleted[i], !inserted[j] { i += 1; j += 1; continue }
            let startI = i, startJ = j
            while i < n, deleted[i] { i += 1 }
            while j < m, inserted[j] { j += 1 }
            if i == startI && j == startJ { break }
            result.append(Change(old: (prefix + startI)..<(prefix + i), new: (prefix + startJ)..<(prefix + j)))
        }
        return result
    }
}
