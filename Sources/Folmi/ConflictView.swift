import FolmiCore
import SwiftUI

extension FolmiModel {
    /// What the two sides of a conflict are called. In a rebase git's "ours" is the upstream being replayed onto and
    /// "theirs" is the user's own commit, the opposite of a merge, so the names follow the operation.
    var conflictSideNames: (ours: String, theirs: String) {
        snapshot?.operation == .rebase ? ("上游已有的", "你的提交") : ("当前分支", "合进来的")
    }

    /// Settles one conflict block (or all, with `block == nil`); ⌥⌘Z puts the markers back.
    func resolveConflict(_ path: String, block: Int?, choice: ConflictFile.Choice, expected: ConflictFile) {
        guard let repository else { return }
        if editorWorkspace?.hasUnsavedChanges == true {
            report(FolmiFailure(message: "编辑器里还有没保存的改动。先保存，再处理冲突。"), title: "仍有编辑草稿"); return
        }
        let name = (path as NSString).lastPathComponent
        mutateUndoable("处理冲突 \(name)", capture: { try await repository.captureWorktree([path]) }) {
            try await repository.resolveConflict(path, block: block, choice: choice, expected: expected)
            let left = try await repository.conflictFile(path)?.blocks.count ?? 0
            return left == 0 ? "\(name) 的冲突都处理了，看一眼再点「标记为已解决」。" : "\(name) 还剩 \(left) 处冲突。"
        }
    }

    func markConflictResolved(_ path: String) {
        guard let repository else { return }
        let name = (path as NSString).lastPathComponent
        mutate("标记已解决 \(name)") {
            try await repository.markResolved(path)
            return "\(name) 已暂存，git 认为它的冲突解决了。"
        }
    }
}

/// A conflicted file, block by block: both sides next to each other and one click to keep either or both.
struct ConflictView: View {
    let model: FolmiModel
    let diff: FileDiff
    @State private var file: ConflictFile?
    @State private var loaded = false
    @Environment(\.folmiTheme) private var theme

    private var path: String { diff.file.path }

    var body: some View {
        let names = model.conflictSideNames
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(names)
                if !loaded {
                    ProgressView().controlSize(.small)
                } else if let file {
                    if file.blocks.isEmpty {
                        resolvedNote
                    } else {
                        ForEach(file.blocks) { block in
                            ConflictBlockCard(block: block, line: Self.line(of: block.index, in: file), names: names, busy: model.busy) { choice in
                                model.resolveConflict(path, block: block.index, choice: choice, expected: file)
                            }
                        }
                    }
                } else {
                    Text("这个文件在一边被删除了，或者不是文本。用编辑器或终端决定留不留它，然后标记为已解决。")
                        .themedFont(.caption, points: 10).foregroundStyle(.secondary)
                    Button("标记为已解决") { model.markConflictResolved(path) }.disabled(model.busy)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: diff.fingerprint) {
            file = try? await model.repository?.conflictFile(path)
            loaded = true
        }
    }

    private func header(_ names: (ours: String, theirs: String)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(ThemeColor(token: .modified))
            VStack(alignment: .leading, spacing: 2) {
                Text(path).themedFont(.system(size: 12, weight: .semibold, design: .monospaced), points: 12)
                    .lineLimit(1).truncationMode(.middle)
                Text(file.map { $0.blocks.isEmpty ? "冲突都处理了" : "\($0.blocks.count) 处冲突：每处选一边，或两边都要" } ?? "冲突文件")
                    .themedFont(.caption, points: 10).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let file, !file.blocks.isEmpty {
                Menu("全部用…") {
                    Button("全部用\(names.ours)的") { model.resolveConflict(path, block: nil, choice: .ours, expected: file) }
                    Button("全部用\(names.theirs)的") { model.resolveConflict(path, block: nil, choice: .theirs, expected: file) }
                }
                .fixedSize().controlSize(.small).disabled(model.busy)
            }
            Button("在编辑器里改") { model.editPath(path) }.controlSize(.small)
        }
    }

    private var resolvedNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("冲突标记都没有了。在编辑器里看一眼结果，没问题就标记为已解决（会暂存这个文件）。")
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("标记为已解决") { model.markConflictResolved(path) }
                .buttonStyle(.folmiProminent).controlSize(.small).disabled(model.busy)
        }
    }

    /// The 1-based line where block `index` starts in the file.
    static func line(of index: Int, in file: ConflictFile) -> Int {
        var line = 1
        for segment in file.segments {
            switch segment {
            case .text(let text): line += ConflictFileLines.count(text)
            case .conflict(let block):
                if block.index == index { return line }
                line += ConflictFileLines.count(block.raw)
            }
        }
        return line
    }
}

private enum ConflictFileLines {
    static func count(_ text: String) -> Int { text.reduce(0) { $1 == "\n" || $1 == "\r\n" ? $0 + 1 : $0 } }
}

private struct ConflictBlockCard: View {
    let block: ConflictBlock
    let line: Int
    let names: (ours: String, theirs: String)
    let busy: Bool
    let choose: (ConflictFile.Choice) -> Void
    @Environment(\.folmiTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("第 \(block.index + 1) 处 · 第 \(line) 行").themedFont(.caption.weight(.medium), points: 10)
                Spacer(minLength: 8)
                Button("用\(names.ours)的") { choose(.ours) }
                Button("用\(names.theirs)的") { choose(.theirs) }
                Menu("两边都要") {
                    Button("\(names.ours)的在前") { choose(.oursThenTheirs) }
                    Button("\(names.theirs)的在前") { choose(.theirsThenOurs) }
                }
                .fixedSize()
            }
            .controlSize(.small).disabled(busy)
            .padding(.horizontal, 10).frame(height: 34)
            .background(ThemeColor(token: .accent, opacity: 0.06))
            HStack(alignment: .top, spacing: 0) {
                side(names.ours, label: block.oursLabel, text: block.ours, token: .removed)
                Divider()
                side(names.theirs, label: block.theirsLabel, text: block.theirs, token: .added)
            }
        }
        .themedBackground(Color.theme(theme, \.card), .control)
        .overlay(RoundedRectangle(cornerRadius: theme.style.radius(.control), style: .continuous)
            .strokeBorder(ThemeColor(token: .border), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: theme.style.radius(.control), style: .continuous))
    }

    private func side(_ name: String, label: String, text: String, token: ThemeToken) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(.themed(token, opacity: 0.65)).frame(width: 5, height: 5)
                Text(name).themedFont(.caption.weight(.medium), points: 10)
                Text(label).themedFont(.caption2.monospaced(), points: 10).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Text(text.isEmpty ? "（这一边是空的）" : String(text.dropLast(text.hasSuffix("\n") ? 1 : 0)))
                .themedFont(.system(size: 12, design: .monospaced), points: 12)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.themed(token, opacity: 0.07))
    }
}
