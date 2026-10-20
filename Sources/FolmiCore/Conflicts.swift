import Foundation

/// A file with conflict markers, cut into plain text and conflict blocks, so each block can be settled with one
/// click (keep one side, or both) instead of editing markers by hand.
public struct ConflictFile: Sendable, Equatable {
    public enum Segment: Sendable, Equatable {
        case text(String)
        case conflict(ConflictBlock)
    }
    public let segments: [Segment]
    public var blocks: [ConflictBlock] {
        segments.compactMap { if case .conflict(let block) = $0 { return block } else { return nil } }
    }

    /// Lines keep their own line endings, so a settled file differs from the original only inside the block.
    public init(_ text: String) {
        var segments: [Segment] = []
        var plain = ""
        var current: (ours: String, base: String?, theirs: String, oursLabel: String, theirsLabel: String, raw: String)?
        enum Part { case ours, base, theirs }
        var part = Part.ours
        for line in Self.lines(text) {
            let bare = line.trimmingCharacters(in: .newlines)
            if current == nil {
                if bare.hasPrefix("<<<<<<<") && (bare.count == 7 || bare.dropFirst(7).first == " ") {
                    if !plain.isEmpty { segments.append(.text(plain)); plain = "" }
                    current = ("", nil, "", Self.label(bare), "", line)
                    part = .ours
                } else { plain += line }
                continue
            }
            current!.raw += line
            if bare.hasPrefix("|||||||"), part == .ours { part = .base; current!.base = ""; continue }
            if bare == "=======", part != .theirs { part = .theirs; continue }
            if bare.hasPrefix(">>>>>>>"), part == .theirs {
                current!.theirsLabel = Self.label(bare)
                let c = current!
                segments.append(.conflict(ConflictBlock(index: segments.filter { if case .conflict = $0 { return true } else { return false } }.count,
                                                        ours: c.ours, base: c.base, theirs: c.theirs,
                                                        oursLabel: c.oursLabel, theirsLabel: c.theirsLabel, raw: c.raw)))
                current = nil
                continue
            }
            switch part {
            case .ours: current!.ours += line
            case .base: current!.base! += line
            case .theirs: current!.theirs += line
            }
        }
        // An unfinished block (no closing marker) is not a conflict git wrote; keep it as text.
        if let open = current { plain += open.raw }
        if !plain.isEmpty { segments.append(.text(plain)) }
        self.segments = segments
    }

    public enum Choice: Sendable, Equatable { case ours, theirs, oursThenTheirs, theirsThenOurs }

    /// The file text with block `index` settled; nil when there is no such block.
    public func resolving(_ index: Int, with choice: Choice) -> String? {
        guard blocks.contains(where: { $0.index == index }) else { return nil }
        return segments.map { segment -> String in
            switch segment {
            case .text(let text): return text
            case .conflict(let block): return block.index == index ? block.text(for: choice) : block.raw
            }
        }.joined()
    }

    /// Every block settled the same way.
    public func resolvingAll(with choice: Choice) -> String {
        segments.map { segment -> String in
            switch segment {
            case .text(let text): return text
            case .conflict(let block): return block.text(for: choice)
            }
        }.joined()
    }

    static func lines(_ text: String) -> [String] {
        var result: [String] = []
        var line = ""
        for character in text {
            line.append(character)
            if character == "\n" || character == "\r\n" { result.append(line); line = "" }
        }
        if !line.isEmpty { result.append(line) }
        return result
    }

    private static func label(_ marker: String) -> String {
        marker.dropFirst(7).trimmingCharacters(in: .whitespaces)
    }
}

public struct ConflictBlock: Sendable, Equatable, Identifiable {
    public let index: Int
    public let ours: String
    public let base: String?
    public let theirs: String
    /// What git wrote after the markers: `HEAD`, a branch name, or a commit and its subject.
    public let oursLabel: String
    public let theirsLabel: String
    /// The block as it is in the file, markers included.
    public let raw: String
    public var id: Int { index }

    public func text(for choice: ConflictFile.Choice) -> String {
        switch choice {
        case .ours: return ours
        case .theirs: return theirs
        case .oursThenTheirs: return Self.joined(ours, theirs)
        case .theirsThenOurs: return Self.joined(theirs, ours)
        }
    }

    private static func joined(_ first: String, _ second: String) -> String {
        guard !first.isEmpty, !first.hasSuffix("\n") else { return first + second }
        return first + "\n" + second
    }
}

extension GitRepository {
    /// The conflicted file as it is on disk; nil when it is gone (a delete / modify conflict) or not UTF-8 text.
    public func conflictFile(_ path: String) async throws -> ConflictFile? {
        let root = try runner().directory
        guard let data = try Self.readWorktreeFile(path, root: root).data, let text = UTF8Text.decode(data) else { return nil }
        return ConflictFile(text)
    }

    /// Writes the file with one block (or all, when `index` is nil) settled, if the file is still what was shown.
    public func resolveConflict(_ path: String, block index: Int?, choice: ConflictFile.Choice, expected: ConflictFile) async throws {
        let root = try runner().directory
        let before = try Self.readWorktreeFile(path, root: root)
        guard let data = before.data, let text = UTF8Text.decode(data), ConflictFile(text) == expected else { throw FolmiError.staleSnapshot }
        let settled: String
        if let index {
            guard let value = expected.resolving(index, with: choice) else { throw FolmiError.invalidSelection }
            settled = value
        } else { settled = expected.resolvingAll(with: choice) }
        try Self.writeWorktreeFile(WorktreeFile(path: path, data: Data(settled.utf8), permissions: before.permissions), root: root)
    }

    /// Stages a conflicted file once no markers are left in it; that is what tells git it is resolved.
    public func markResolved(_ path: String) async throws {
        if let file = try await conflictFile(path), !file.blocks.isEmpty {
            throw FolmiError.unsupported("\(path) 里还有 \(file.blocks.count) 处冲突没处理。")
        }
        let git = try runner()
        let exists = FileManager.default.fileExists(atPath: git.directory.appendingPathComponent(path).path)
        _ = try git.run(exists ? ["add", "--", path] : ["rm", "--cached", "--quiet", "--", path])
    }
}
