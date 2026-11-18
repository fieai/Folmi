import AppKit
import FolmiCore
import Observation
import SwiftUI

struct AgentAttention: Equatable {
    enum Kind: Int {
        case running, review, failed, waiting

        var color: Color {
            switch self {
            case .running: .secondary
            case .review: .blue
            case .failed: .red
            case .waiting: .orange
            }
        }
    }

    let kind: Kind
    let text: String

    static func highest(_ first: Self?, _ second: Self?) -> Self? {
        guard let first else { return second }
        guard let second, second.kind.rawValue > first.kind.rawValue else { return first }
        return second
    }

    static func waiting(agent: String, message: String?) -> Self {
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(kind: .waiting, text: "\(agent) 在等你处理" + (message.isEmpty ? "" : "：" + message))
    }

    static func hook(_ event: AIEvent, unaccepted: Int, now: Date = Date()) -> Self? {
        let agent = event.agent == "codex" ? "Codex" : "Claude"
        let age = now.timeIntervalSince1970 - event.t
        switch event.kind {
        case .waiting:
            guard age < 30 * 60 else { return nil }
            return waiting(agent: agent, message: event.message)
        case .stop:
            guard age < 24 * 3600, unaccepted > 0 else { return nil }
            return Self(kind: .review, text: "\(agent) 改完了 · \(unaccepted) 个文件没验收")
        case .start, .edit:
            guard age < 30 * 60 else { return nil }
            return Self(kind: .running, text: "\(agent) 正在改")
        }
    }
}

struct AgentAttentionBadge: View {
    let attention: AgentAttention
    var backdrop: ThemeToken = .card

    var body: some View {
        Circle().fill(ThemeColor(token: backdrop))
            .frame(width: 10, height: 10)
            .overlay {
                if attention.kind == .running {
                    Circle().strokeBorder(attention.kind.color, lineWidth: 1).frame(width: 7, height: 7)
                } else {
                    Circle().fill(attention.kind.color).frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Follows the log as hooks create, append to or replace it. A directory watch fills in until the file exists.
@MainActor
final class AgentEventWatch {
    private let gitDir: URL
    private let events: URL
    private let onChange: (AIEvent?) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var watchedURL: URL?
    private(set) var last: AIEvent?

    init(gitDir: URL, onChange: @escaping (AIEvent?) -> Void) {
        self.gitDir = gitDir
        events = AIEventStore.events(gitDir: gitDir)
        self.onChange = onChange
    }

    deinit { source?.cancel() }

    func start() { if source == nil { update(rearm: true) } }

    private func arm() {
        source?.cancel()
        source = nil
        watchedURL = nil
        for url in [events, events.deletingLastPathComponent(), gitDir] {
            let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                   eventMask: [.write, .extend, .delete, .rename, .revoke],
                                                                   queue: .main)
            watcher.setCancelHandler { close(fd) }
            watcher.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let current = self.source, current.handle == fd else { return }
                    let replaced = !current.data.intersection([.delete, .rename, .revoke]).isEmpty
                    if replaced || (url != self.events && self.canWatchCloser(than: url)) {
                        self.update(rearm: true)
                    } else if url == self.events {
                        self.update(rearm: false)
                    }
                }
            }
            source = watcher
            watchedURL = url
            watcher.resume()
            return
        }
    }

    private func canWatchCloser(than url: URL) -> Bool {
        let target = url == gitDir ? events.deletingLastPathComponent() : events
        return FileManager.default.fileExists(atPath: target.path)
    }

    private func update(rearm: Bool) {
        if rearm { arm() }
        var latest = Self.lastEvent(at: events)
        // Creation can race opening the parent directory. Attach to the file before publishing its first event.
        if rearm, watchedURL != events, latest != nil {
            arm()
            latest = Self.lastEvent(at: events)
        }
        guard last != latest else { return }
        last = latest
        onChange(latest)
    }

    static func lastEvent(at url: URL) -> AIEvent? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let count = min(size, 4_096)
        try? handle.seek(toOffset: size - count)
        guard let data = try? handle.read(upToCount: Int(count)) else { return nil }
        return AIEventStore.parse(data).events.last
    }
}

extension FolmiModel {
    func observeAgentAttention() {
        let reports = withObservationTracking {
            var reports: [String: AgentAttention] = [:]
            for session in agentSessions where !session.restored && !session.isReadOnly {
                let path = session.root.path
                let attention: AgentAttention?
                if session.needsPermission {
                    let message = session.transcript.entries.last { $0.kind == .permission && $0.status == nil }?.text
                    attention = .waiting(agent: session.agent.title, message: message)
                } else if case .failed = session.state, session.unseen {
                    attention = AgentAttention(kind: .failed, text: "\(session.agent.title) 出错了")
                } else {
                    attention = nil
                }
                reports[path] = AgentAttention.highest(reports[path], attention)
            }
            return reports
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAgentAttention() }
        }
        board.updateAgentAttention(reports)
    }
}
