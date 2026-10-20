import Darwin
import Foundation
import FolmiCore

struct QuickOpenMatch: Identifiable, Equatable, Sendable {
    let path: String
    let score: Int
    let line: Int?
    let column: Int?
    var id: String { path }
}

enum QuickOpenMatcher {
    /// Empty queries preserve the caller's order, allowing recent files to come first.
    static func matches(paths: [String], query: String, limit: Int = 100) -> [QuickOpenMatch] {
        guard limit > 0 else { return [] }
        let parsed = parseQuery(query)
        let needle = folded(parsed.path)
        var seen: Set<String> = []
        var results: [QuickOpenMatch] = []
        for path in paths where ProjectSearchPath.components(path) != nil && seen.insert(path).inserted {
            guard let score = score(path: path, query: needle) else { continue }
            results.append(QuickOpenMatch(path: path, score: score, line: parsed.line, column: parsed.column))
            if needle.isEmpty && results.count == limit { break }
        }
        if !needle.isEmpty {
            results.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                let order = $0.path.localizedStandardCompare($1.path)
                return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
            }
        }
        return Array(results.prefix(limit))
    }

    private static func parseQuery(_ raw: String) -> (path: String, line: Int?, column: Int?) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = query.split(separator: ":", omittingEmptySubsequences: false)
        func positive(_ part: Substring) -> Int? {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part), value > 0 else { return nil }
            return value
        }
        if components.count >= 3,
           let line = positive(components[components.count - 2]),
           let column = positive(components[components.count - 1]) {
            return (components.dropLast(2).joined(separator: ":"), line, column)
        }
        if components.count >= 2, let line = positive(components[components.count - 1]) {
            return (components.dropLast().joined(separator: ":"), line, nil)
        }
        return (query, nil, nil)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func score(path: String, query: String) -> Int? {
        if query.isEmpty { return 0 }
        let haystack = folded(path)
        let filename = haystack.split(separator: "/").last.map(String.init) ?? haystack
        let lengthPenalty = min(haystack.count, 200)
        if filename == query { return 10_000 - lengthPenalty }
        if filename.hasPrefix(query) { return 9_000 - lengthPenalty }
        if filename.contains(query) { return 8_000 - lengthPenalty }
        if haystack == query { return 7_000 - lengthPenalty }
        if haystack.hasPrefix(query) { return 6_000 - lengthPenalty }
        if haystack.contains(query) { return 5_000 - lengthPenalty }
        if let fuzzy = subsequenceScore(needle: query, haystack: filename) { return 3_000 + min(fuzzy, 999) - lengthPenalty }
        if let fuzzy = subsequenceScore(needle: query, haystack: haystack) { return 1_000 + min(fuzzy, 999) - lengthPenalty }
        return nil
    }

    private static func subsequenceScore(needle: String, haystack: String) -> Int? {
        let wanted = Array(needle)
        var matched = 0
        var previousOffset = -2
        var score = 0
        var previous: Character?
        for (offset, character) in haystack.enumerated() {
            guard matched < wanted.count else { break }
            if character == wanted[matched] {
                score += 3
                if offset == previousOffset + 1 { score += 5 }
                if offset == 0 || previous == "/" || previous == "_" || previous == "-" || previous == "." || previous == " " {
                    score += 8
                }
                if matched == 0 { score -= min(offset, 100) }
                previousOffset = offset
                matched += 1
            }
            previous = character
        }
        return matched == wanted.count ? score : nil
    }
}

struct ProjectSearchHit: Identifiable, Equatable, Sendable {
    let path: String
    /// One-based line and UTF-16 column (excluding a first-line BOM); range retains original text's UTF-16 units.
    let line: Int
    let column: Int
    let range: NSRange
    let preview: String
    var id: String { "\(path):\(range.location):\(range.length)" }
}

struct ProjectSearchResult: Sendable {
    let hits: [ProjectSearchHit]
    /// Files completely read, or supplied as open documents, including unsupported text skipped afterward.
    let scannedFiles: Int
    let isTruncated: Bool
    let notice: String?
}

enum ProjectSearchError: Error, LocalizedError {
    case invalidRoot
    case protectedRoot
    case cannotReadRoot(String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot: return "搜索目录不可用，或它是符号链接。"
        case .protectedRoot: return "项目搜索不读取 Git 元数据。"
        case .cannotReadRoot(let message): return "无法读取项目目录：\(message)"
        }
    }
}

private enum ProjectSearchPath {
    static func components(_ path: String) -> [String]? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.caseInsensitiveCompare(".git") != .orderedSame }) else {
            return nil
        }
        return parts
    }

    static func containsGit(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.caseInsensitiveCompare(".git") == .orderedSame }
    }
}

/// Literal, bounded search over scanned project paths and safely named open documents.
/// Every descent is anchored to an open directory; links and Git metadata are never followed.
enum ProjectTextSearch {
    struct Limits {
        let maximumFileBytes: Int
        let maximumTotalBytes: Int
        let maximumFiles: Int
        let maximumHits: Int
        let maximumHitsPerFile: Int
        static let `default` = Limits(maximumFileBytes: 2 * 1_024 * 1_024,
                                      maximumTotalBytes: 64 * 1_024 * 1_024,
                                      maximumFiles: 10_000, maximumHits: 1_000, maximumHitsPerFile: 200)
    }

    static func search(root: URL, paths: [String], query: String, caseSensitive: Bool = false,
                       openDocuments: [String: String] = [:],
                       isCancelled: () -> Bool = { false }) throws -> ProjectSearchResult {
        try search(root: root, paths: paths, query: query, caseSensitive: caseSensitive,
                   limits: .default, openDocuments: openDocuments, isCancelled: isCancelled)
    }

    static func search(root: URL, paths: [String], query: String, caseSensitive: Bool = false,
                       limits: Limits, openDocuments: [String: String] = [:],
                       isCancelled: () -> Bool = { false }) throws -> ProjectSearchResult {
        func checkCancellation() throws { if isCancelled() { throw CancellationError() } }
        try checkCancellation()
        guard !query.isEmpty else {
            return ProjectSearchResult(hits: [], scannedFiles: 0, isTruncated: false, notice: nil)
        }
        guard root.isFileURL else { throw ProjectSearchError.invalidRoot }
        guard !ProjectSearchPath.containsGit(root.path) else { throw ProjectSearchError.protectedRoot }
        var attributes = stat()
        guard root.path.withCString({ lstat($0, &attributes) }) == 0,
              attributes.st_mode & S_IFMT == S_IFDIR,
              let canonicalPointer = root.path.withCString({ realpath($0, nil) }) else {
            throw ProjectSearchError.invalidRoot
        }
        defer { free(canonicalPointer) }
        let canonicalPath = String(cString: canonicalPointer)
        guard !ProjectSearchPath.containsGit(canonicalPath) else { throw ProjectSearchError.protectedRoot }
        let rootDescriptor = canonicalPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootDescriptor >= 0 else { throw ProjectSearchError.cannotReadRoot(String(cString: strerror(errno))) }
        defer { close(rootDescriptor) }

        var seen: Set<String> = []
        let candidates = (paths + openDocuments.keys.sorted()).compactMap { path -> (String, [String])? in
            guard let parts = ProjectSearchPath.components(path), seen.insert(path).inserted else { return nil }
            return (path, parts)
        }
        var hits: [ProjectSearchHit] = []
        var scannedFiles = 0
        var visitedFiles = 0
        var totalBytes = 0
        var isTruncated = false
        var notices: [String] = []
        var skippedBinary = 0
        var skippedLarge = 0
        var skippedUnavailable = 0
        var skippedChanged = 0
        var usedOpenDocuments = false
        func addNotice(_ notice: String) {
            if !notices.contains(notice) { notices.append(notice) }
        }
        let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]

        for (path, components) in candidates {
            try checkCancellation()
            guard visitedFiles < max(0, limits.maximumFiles) else {
                isTruncated = true
                addNotice("最多搜索 \(limits.maximumFiles) 个文件")
                break
            }
            visitedFiles += 1
            guard hits.count < max(0, limits.maximumHits) else {
                isTruncated = true
                addNotice("最多显示 \(limits.maximumHits) 处命中")
                break
            }
            let text: String
            if let document = openDocuments[path] {
                try checkCancellation()
                let byteCount = document.utf8.count
                guard byteCount <= max(0, limits.maximumFileBytes) else { skippedLarge += 1; continue }
                guard byteCount <= max(0, limits.maximumTotalBytes) - totalBytes else {
                    isTruncated = true
                    addNotice("已达到总读取预算 \(formattedBytes(limits.maximumTotalBytes))，部分文件未搜索")
                    continue
                }
                totalBytes += byteCount
                scannedFiles += 1
                usedOpenDocuments = true
                guard !document.utf8.contains(0) else { skippedBinary += 1; continue }
                text = document
            } else {
                guard let descriptor = openFile(rootDescriptor: rootDescriptor, components: components) else {
                    skippedUnavailable += 1
                    continue
                }
                defer { close(descriptor) }
                var before = stat()
                guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                      before.st_size >= 0 else {
                    skippedUnavailable += 1
                    continue
                }
                guard before.st_size <= max(0, limits.maximumFileBytes) else {
                    skippedLarge += 1
                    continue
                }
                let expectedBytes = Int(before.st_size)
                guard expectedBytes <= max(0, limits.maximumTotalBytes) - totalBytes else {
                    isTruncated = true
                    addNotice("已达到总读取预算 \(formattedBytes(limits.maximumTotalBytes))，部分文件未搜索")
                    continue
                }
                var bytes = Data()
                bytes.reserveCapacity(expectedBytes)
                var buffer = [UInt8](repeating: 0, count: min(65_536, max(1, expectedBytes)))
                var failedRead = false
                while bytes.count < expectedBytes {
                    try checkCancellation()
                    let wanted = min(buffer.count, expectedBytes - bytes.count)
                    let count = buffer.withUnsafeMutableBytes { pointer in Darwin.read(descriptor, pointer.baseAddress, wanted) }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { failedRead = true; break }
                    bytes.append(contentsOf: buffer.prefix(count))
                    totalBytes += count
                }
                guard !failedRead else { skippedUnavailable += 1; continue }
                var after = stat()
                guard fstat(descriptor, &after) == 0,
                      after.st_size == before.st_size,
                      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
                    skippedChanged += 1
                    continue
                }
                scannedFiles += 1
                guard !bytes.contains(0), let decoded = UTF8Text.decode(bytes) else {
                    skippedBinary += 1
                    continue
                }
                text = decoded
            }
            let string = text as NSString
            guard string.length > 0 else { continue }
            var searchRange = NSRange(location: 0, length: string.length)
            var fileHits = 0
            var lineStarts: [Int]?
            while searchRange.length > 0 {
                try checkCancellation()
                let match = string.range(of: query, options: options, range: searchRange)
                guard match.location != NSNotFound, match.length > 0 else { break }
                if hits.count >= max(0, limits.maximumHits) {
                    isTruncated = true
                    addNotice("最多显示 \(limits.maximumHits) 处命中")
                    break
                }
                if fileHits >= max(0, limits.maximumHitsPerFile) {
                    isTruncated = true
                    addNotice("每个文件最多显示 \(limits.maximumHitsPerFile) 处命中")
                    break
                }
                if lineStarts == nil { lineStarts = makeLineStarts(string) }
                let starts = lineStarts!
                let lineIndex = lineIndex(containing: match.location, starts: starts)
                let firstLineBOM = lineIndex == 0 && string.character(at: 0) == 0xFEFF ? 1 : 0
                hits.append(ProjectSearchHit(path: path, line: lineIndex + 1,
                                             column: max(1, match.location - starts[lineIndex] + 1 - firstLineBOM),
                                             range: match,
                                             preview: preview(string, match: match, lineIndex: lineIndex, starts: starts)))
                fileHits += 1
                let next = NSMaxRange(match)
                searchRange = NSRange(location: next, length: string.length - next)
            }
        }
        try checkCancellation()
        if usedOpenDocuments { addNotice("含打开文档的当前内容（包括未保存编辑）") }
        if skippedLarge > 0 { addNotice("跳过 \(skippedLarge) 个超过 \(formattedBytes(limits.maximumFileBytes)) 的文件") }
        if skippedBinary > 0 { addNotice("跳过 \(skippedBinary) 个二进制或非 UTF-8 文件") }
        if skippedUnavailable > 0 { addNotice("跳过 \(skippedUnavailable) 个链接、非普通或不可读文件") }
        if skippedChanged > 0 { addNotice("跳过 \(skippedChanged) 个搜索时发生变化的文件，可重新搜索") }
        return ProjectSearchResult(hits: hits, scannedFiles: scannedFiles, isTruncated: isTruncated,
                                   notice: notices.isEmpty ? nil : notices.joined(separator: "；"))
    }

    private static func openFile(rootDescriptor: Int32, components: [String]) -> Int32? {
        var directory = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = component.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { return nil }
            close(directory)
            directory = next
        }
        guard let name = components.last else { return nil }
        let result = name.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        return result >= 0 ? result : nil
    }

    private static func makeLineStarts(_ string: NSString) -> [Int] {
        var starts = [0]
        var offset = 0
        while offset < string.length {
            let character = string.character(at: offset)
            if character == 13 {
                if offset + 1 < string.length, string.character(at: offset + 1) == 10 { offset += 1 }
                starts.append(offset + 1)
            } else if character == 10 { starts.append(offset + 1) }
            offset += 1
        }
        return starts
    }

    private static func lineIndex(containing offset: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = low + (high - low) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    private static func preview(_ string: NSString, match: NSRange, lineIndex: Int, starts: [Int]) -> String {
        let lineStart = starts[lineIndex]
        var lineEnd = lineIndex + 1 < starts.count ? starts[lineIndex + 1] : string.length
        while lineEnd > lineStart && [UInt16(10), 13].contains(string.character(at: lineEnd - 1)) { lineEnd -= 1 }
        var start = max(lineStart, match.location - 50)
        var end = min(lineEnd, start + 180)
        // NSString indices are UTF-16; do not cut the surrogate pair of an emoji in the preview.
        if start > lineStart, start < string.length, (0xDC00...0xDFFF).contains(string.character(at: start)),
           (0xD800...0xDBFF).contains(string.character(at: start - 1)) { start -= 1 }
        if end > start, end < string.length, (0xDC00...0xDFFF).contains(string.character(at: end)),
           (0xD800...0xDBFF).contains(string.character(at: end - 1)) { end -= 1 }
        let excerpt = string.substring(with: NSRange(location: start, length: end - start))
            .replacingOccurrences(of: "\t", with: "  ")
        return (start > lineStart ? "…" : "") + String(excerpt.prefix(196)) + (end < lineEnd || excerpt.count > 196 ? "…" : "")
    }

    private static func formattedBytes(_ bytes: Int) -> String {
        if bytes >= 1_024 * 1_024 { return "\(bytes / (1_024 * 1_024)) MiB" }
        return "\(bytes) B"
    }
}
