import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// `--perf-run`: drives the window through the switches scripts/perf.sh measures, then quits.
extension FolmiModel {
    /// `--perf-run`: walks through the changed files' diffs, then the largest Markdown files in reading mode (each
    /// twice, so the second visit shows a switch back to an open tab), and quits. Timings go to `--perf-log`.
    func runPerfScript() {
        // Installing each destination invokes this entry point again; only the initial install owns the script.
        guard PerfLog.beginScriptRun() else { return }
        Task { @MainActor in
            // An unattended benchmark may be inactive; App Nap must not coalesce its heartbeat timer.
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                 reason: "Folmi performance measurement")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            // A restored reader must be visible for WebKit's frame callbacks to run during measurement.
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
            let measuredProjects = ["perf-large", "perf-huge"].compactMap { name in projects.first { $0.name == name } }
            if !measuredProjects.isEmpty {
                let selection = (area: area, ids: selectedFileIDs, id: selectedFileID)
                let savedContent = content, savedLayout = paneLayout
                let editorColumns = editorWorkspace?.columns
                let markdownReading = editorWorkspace?.markdownReading
                showSideTab(.changes)
                await waitForPerfFrame()
                for project in measuredProjects {
                    let metric = project.name == "perf-huge" ? "switch.hugeProject" : "switch.largeProject"
                    for _ in 0..<3 {
                        PerfLog.beginLargeProjectSwitch(root: URL(fileURLWithPath: project.rootPath), metric: metric)
                        switchProject(project.rootPath)
                        guard await waitForPerfProject(project.rootPath, measured: true) else { break }
                        switchProject(root.path)
                        guard await waitForPerfProject(root.path) else { break }
                        await waitForPerfFrame()
                    }
                }
                // Restore exactly where the original script quit. editPath would also replace the diff selection.
                area = selection.area; selectedFileIDs = selection.ids; selectedFileID = selection.id
                content = savedContent; paneLayout = savedLayout
                if let editorColumns { editorWorkspace?.columns = editorColumns }
                if let markdownReading { editorWorkspace?.markdownReading = markdownReading }
            }
            NSApp.terminate(nil)
        }
    }

    private func waitForPerfFrame() async {
        // A loaded project can still have a reader/list layout queued for its first frame.
        // Finish that frame before starting the next project's measurement.
        await withCheckedContinuation { continuation in
            PerfLog.afterFrame { continuation.resume() }
        }
    }

    private func waitForPerfProject(_ path: String, measured: Bool = false) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while busy || repositoryURL?.path != path || (measured && PerfLog.largeProjectSwitchPending) {
            guard ContinuousClock.now < deadline else {
                PerfLog.note("error", "切换项目超时：\(path)")
                return false
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
