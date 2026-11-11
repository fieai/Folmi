import FolmiCore
import SwiftUI

/// The unchanged lines between two displayed context rows, or from a file edge to one of them.
struct DiffContextGap: Sendable {
    let previous: AlignedDiffRow?
    let next: AlignedDiffRow?

    init?(after previous: AlignedDiffRow?, before next: AlignedDiffRow?) {
        guard previous != nil || next != nil else { return nil }
        for row in [previous, next].compactMap({ $0 }) {
            guard row.old?.line.kind == .context, row.new?.line.kind == .context,
                  row.old?.lineNumber != nil, row.new?.lineNumber != nil else { return nil }
        }
        self.previous = previous; self.next = next
        if let count, count <= 0 { return nil }
    }

    var count: Int? { next?.new?.lineNumber.map { $0 - (previous?.new?.lineNumber ?? 0) - 1 } }

    struct Content: Sendable {
        let rows: [AlignedDiffRow]
        let remaining: Int
    }

    func read(versions: FileVersions, repository: GitRepository) async throws -> Content {
        let limit = 2 * 1_024 * 1_024
        guard let old = versions.old, let new = versions.new,
              let before = try await repository.bytes(of: old, limit: limit),
              let after = try await repository.bytes(of: new, limit: limit) else { throw FolmiError.staleSnapshot }
        let work = Task.detached(priority: .userInitiated) { try content(old: before, new: after) }
        return try await work.value
    }

    func content(old: Data, new: Data) throws -> Content {
        func unchanged(_ data: Data, from: AlignedDiffCell?, to: AlignedDiffCell?) throws -> ArraySlice<String> {
            guard !data.contains(0), let text = UTF8Text.decode(data) else {
                throw FolmiError.unsupported("这份文件的上下文无法显示为文本。")
            }
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            for anchor in [from, to].compactMap({ $0 }) {
                guard let number = anchor.lineNumber, lines.indices.contains(number - 1),
                      lines[number - 1] == anchor.line.text else { throw FolmiError.staleSnapshot }
            }
            let start = from?.lineNumber ?? 0, end = to?.lineNumber.map { $0 - 1 } ?? lines.count
            guard start <= end else { throw FolmiError.staleSnapshot }
            return lines[start..<end]
        }
        let before = try unchanged(old, from: previous?.old, to: next?.old)
        let after = try unchanged(new, from: previous?.new, to: next?.new)
        // An edit since the diff was loaded must not be presented as unchanged context.
        guard before.elementsEqual(after) else { throw FolmiError.staleSnapshot }
        let limit = 200
        let shown = previous == nil ? before.suffix(limit) : before.prefix(limit)
        let newOffset = after.startIndex - before.startIndex
        let rows = shown.indices.map { index in
            let line = DiffLine(id: index, text: before[index], kind: .context)
            return AlignedDiffRow(id: index, old: .init(line: line, lineNumber: index + 1),
                                  new: .init(line: line, lineNumber: index + newOffset + 1))
        }
        return Content(rows: rows, remaining: before.count - rows.count)
    }
}

struct DiffContextView: View {
    let gap: DiffContextGap
    let versions: FileVersions
    let unified: Bool
    @Environment(\.gitRepository) private var repository
    @State private var expanded = false
    @State private var content: DiffContextGap.Content?
    @State private var failure: String?

    var body: some View {
        if let repository {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    expanded.toggle()
                } label: {
                    Label(title, systemImage: expanded ? "chevron.up" : "chevron.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).themedFont(.caption, points: 10).foregroundStyle(.secondary)
                .background(.themed(.header, opacity: 0.45))
                if expanded { expandedContent }
            }
            .task(id: expanded) {
                guard expanded, content == nil else { return }
                failure = nil
                do {
                    let loaded = try await gap.read(versions: versions, repository: repository)
                    if !Task.isCancelled { content = loaded }
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
            }
        }
    }

    private var title: String {
        if expanded { return "折叠上下文" }
        if let count = gap.count ?? content.map({ $0.rows.count + $0.remaining }) {
            return count == 0 ? "已到文件末尾" : "展开 \(count) 行上下文"
        }
        return "展开后续上下文"
    }

    @ViewBuilder private var expandedContent: some View {
        if let content {
            if content.rows.isEmpty {
                notice("已到文件末尾")
            } else {
                DiffRowsView(rows: content.rows, rowsKey: "context", selected: [], canSelect: false,
                             unified: unified, onToggle: { _ in })
                    .frame(height: DiffCanvasMetrics.height(rows: content.rows.count))
                if content.remaining > 0 { notice("另有 \(content.remaining) 行，请在编辑器查看。") }
            }
        } else if let failure {
            notice(failure)
        } else {
            ProgressView().controlSize(.mini).padding(8).accessibilityLabel("正在读取上下文")
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).themedFont(.caption, points: 10).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
    }
}
