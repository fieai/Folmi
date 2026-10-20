import AppKit
import Quartz
import SwiftUI

/// Space in the file tree: the system Quick Look panel, like Finder.
@MainActor
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreview()
    private var url: URL?

    func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, self.url == url { panel.orderOut(nil); return }
        self.url = url
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}

/// Done / total task boxes of a Markdown file, for the ring in the file tree.
struct TaskCount: Equatable {
    let done: Int
    let total: Int
}

/// A small ring with "2/4" beside it.
struct TaskRing: View {
    let count: TaskCount
    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                Circle().trim(from: 0, to: CGFloat(count.done) / CGFloat(max(1, count.total)))
                    .stroke(count.done == count.total ? ThemeColor(token: .added) : ThemeColor(token: .accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 10, height: 10)
            Text("\(count.done)/\(count.total)").themedFont(.system(size: 9, weight: .medium).monospacedDigit(), points: 9).foregroundStyle(.secondary)
        }
        .help("任务 \(count.done)/\(count.total) 已完成")
    }
}
