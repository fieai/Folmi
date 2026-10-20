import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// `--perf-run`: drives the window through the switches scripts/perf.sh measures, then quits.
extension FolmiModel {
    /// `--perf-run`: walks through the changed files' diffs, then the largest Markdown files in reading mode (each
    /// twice, so the second visit shows a switch back to an open tab), and quits. Timings go to `--perf-log`.
    func runPerfScript() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            PerfLog.launchOver = true
            // Like a person going down the changes list: the list is what is on screen.
            showSideTab(.changes)
            for file in filesInArea.prefix(8) {
                selectFiles([file.id]); try? await Task.sleep(for: .milliseconds(700))
            }
            guard let root = repositoryURL else { NSApp.terminate(nil); return }
            let size = { (path: String) in
                ((try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.size]) as? NSNumber)?.intValue ?? 0
            }
            // Like an agent editing a file in the terminal: the watcher refreshes the status and the window follows.
            if let file = filesInArea.first(where: { $0.path.hasSuffix(".md") }) {
                let url = root.appendingPathComponent(file.path)
                for round in 0..<3 {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        handle.seekToEndOfFile(); handle.write(Data("\n外部改动 \(round)\n".utf8)); try? handle.close()
                    }
                    try? await Task.sleep(for: .milliseconds(1500))
                }
            }
            showSideTab(.files)
            let sizes = Dictionary(browserPaths.filter { $0.lowercased().hasSuffix(".md") }.map { ($0, size($0)) }, uniquingKeysWith: { a, _ in a })
            let markdown = sizes.keys.sorted { sizes[$0]! != sizes[$1]! ? sizes[$0]! > sizes[$1]! : $0 < $1 }.prefix(5)
            editorWorkspace?.markdownReading = true
            for pass in 0..<2 {
                for path in markdown {
                    PerfLog.beginReaderSwitch(path, label: pass == 0 ? "first" : "again")
                    editPath(path); editorWorkspace?.markdownReading = true
                    try? await Task.sleep(for: .milliseconds(900))
                }
            }
            // Through a code file and back: the reader's web view is torn down for the code file and built again.
            if let code = browserPaths.first(where: { !$0.lowercased().hasSuffix(".md") && size($0) > 0 }), let back = markdown.first {
                for _ in 0..<3 {
                    editPath(code); try? await Task.sleep(for: .milliseconds(600))
                    PerfLog.beginReaderSwitch(back, label: "fromCode")
                    editPath(back); try? await Task.sleep(for: .milliseconds(900))
                }
            }
            NSApp.terminate(nil)
        }
    }
}
