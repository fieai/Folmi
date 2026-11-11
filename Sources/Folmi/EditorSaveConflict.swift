import AppKit
import SwiftUI

struct EditorSaveConflict: Identifiable {
    let path: String
    let draft: String
    let disk: String?
    let diskError: String?
    var id: String { path }
}

struct EditorSaveConflictSheet: View {
    let conflict: EditorSaveConflict
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("比较两个版本").font(.headline)
            Text(conflict.path).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let disk = conflict.disk {
                let changes = GutterDiff.changes(base: disk, current: conflict.draft)
                HStack(spacing: 12) {
                    version("磁盘上的版本", text: disk, changed: changes.map(\.old), tint: .systemRed)
                    version("我的草稿", text: conflict.draft, changed: changes.map(\.new), tint: .systemGreen)
                }
                if changes.isEmpty {
                    Text("两边显示的文字相同，文件的编码或换行仍可能有差异。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("无法读取磁盘上的版本。\(conflict.diskError ?? "")").foregroundStyle(.secondary)
                version("我的草稿", text: conflict.draft, changed: [], tint: .systemGreen)
            }
            HStack {
                Button("复制我的草稿") { FileActionsMenu.copy(conflict.draft) }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 680, idealWidth: 820, minHeight: 360, idealHeight: 490)
    }

    private func version(_ title: String, text: String, changed: [Range<Int>], tint: NSColor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ConflictText(text: text, changed: changed, tint: tint)
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ConflictText: NSViewRepresentable {
    let text: String
    let changed: [Range<Int>]
    let tint: NSColor

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isEditable = false
        editor.isSelectable = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        let contents = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ])
        let starts = MarkdownReaderView.Coordinator.lineStarts(text)
        for lines in changed where !lines.isEmpty {
            let start = starts[lines.lowerBound]
            let end = lines.upperBound < starts.count ? starts[lines.upperBound] : contents.length
            contents.addAttribute(.backgroundColor, value: tint.withAlphaComponent(0.18),
                                  range: NSRange(location: start, length: end - start))
        }
        editor.textStorage?.setAttributedString(contents)
        if let line = changed.first?.lowerBound, line < starts.count {
            let location = starts[line]
            DispatchQueue.main.async { [weak editor] in
                editor?.scrollRangeToVisible(NSRange(location: location, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}
