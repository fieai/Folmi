import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// The adapter owns the list; local records only identify conversations opened here.
@MainActor
@Observable
final class AgentSessionList {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var cwd: String
        var updatedAt: Date?
    }

    struct Group: Identifiable {
        var title: String
        var sessions: [Item]
        var id: String { title }
    }

    private(set) var sessions: [Item] = []
    private(set) var supportsList: Bool?
    private(set) var supportsLoad: Bool?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var revision = UUID()

    func refresh(session: AgentSession, command: String) async {
        let revision = UUID()
        self.revision = revision
        isLoading = true
        error = nil
        sessions = []
        supportsList = session.supportsSessionList
        supportsLoad = session.supportsSessionLoad
        defer { if self.revision == revision { isLoading = false } }
        do {
            // Listing shares the conversation's adapter and needs no session of its own.
            let connection = try await session.host.connect(command)
            guard self.revision == revision, !Task.isCancelled else { return }
            supportsList = session.supportsSessionList
            supportsLoad = session.supportsSessionLoad
            guard supportsList == true else { return }
            let listed = try await Self.fetch(connection: connection, cwd: session.root.path)
            guard self.revision == revision, !Task.isCancelled else { return }
            sessions = listed
        } catch {
            guard self.revision == revision, !Task.isCancelled else { return }
            self.error = (error as? ACPError)?.message ?? error.localizedDescription
        }
    }

    private static func fetch(connection: ACPConnection, cwd: String) async throws -> [Item] {
        var items: [Item] = [], ids: Set<String> = [], cursors: Set<String> = []
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            var params: [String: JSON] = ["cwd": .string(cwd)]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await connection.request("session/list", .object(params))
            for value in page["sessions"]?.array ?? [] {
                // The adapter already filters by cwd and normalizes the path; comparing strings again here would drop
                // every session when the project is reached through a symlink (/var vs /private/var).
                guard let id = value["sessionId"]?.string, ids.insert(id).inserted else { continue }
                let title = value["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                items.append(Item(id: id, title: title.isEmpty ? "未命名会话" : title, cwd: cwd,
                                  updatedAt: date(value["updatedAt"]?.string)))
                if items.count == 200 { break }
            }
            cursor = page["nextCursor"]?.string
            if let cursor, !cursors.insert(cursor).inserted { break }
        } while cursor != nil && items.count < 200
        return items.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// `open` are the conversations in tabs (with `current`); they head the list as 打开着.
    func groups(current: AgentSession, open: [AgentSession] = [], search: String = "") -> [Group] {
        let local = AgentSession.savedSessionIDs(gitDir: current.gitDir, agent: current.agent)
        let tabs = ([current] + open.filter { $0 !== current }).filter { $0.agent == current.agent }
        var items = sessions
        for tab in tabs.reversed() {
            guard let id = tab.sessionID, !items.contains(where: { $0.id == id }) else { continue }
            items.insert(Item(id: id, title: tab.displayTitle, cwd: tab.root.path, updatedAt: tab.started), at: 0)
        }
        let openIDs = Set(tabs.compactMap(\.sessionID))
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        items = items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        return [
            Group(title: "打开着", sessions: items.filter { openIDs.contains($0.id) }),
            Group(title: "在 Folmi 开的", sessions: items.filter { !openIDs.contains($0.id) && local.contains($0.id) }),
            Group(title: "在别处开的（Codex CLI、App 等）", sessions: items.filter { !openIDs.contains($0.id) && !local.contains($0.id) }),
        ].filter { !$0.sessions.isEmpty }
    }

    static func relativeTime(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes == 0 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MM/dd" : "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}

extension FolmiModel {
    /// Already in a tab: show it. Otherwise a read-only tab with the conversation's record.
    func openAgentSession(_ item: AgentSessionList.Item) {
        guard let current = agentSession else { return }
        if let open = agentSessions.first(where: { $0.sessionID == item.id && !$0.restored }) {
            selectAgentSession(open); return
        }
        let session = AgentSession(agent: current.agent, root: current.root, gitDir: current.gitDir)
        show(session, replacingSpare: true)
        Task { await session.showRecord(id: item.id, title: item.title) }
    }

    /// `codex resume <id>` at the terminal prompt, not run.
    func resumeInTerminal(_ id: String) {
        if !showTerminal || terminalSession == nil { focusPane(.terminal) }
        aiTabSelected = false
        let quoted = "'" + id.replacingOccurrences(of: "'", with: "'\\''") + "'"
        sendTextToTerminal("codex resume " + quoted)
    }
}

struct AgentSessionListView: View {
    let model: FolmiModel
    let list: AgentSessionList
    @State private var search = ""
    var onOpen: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索会话", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索会话")
            HStack {
                Text("会话").themedFont(.caption.weight(.medium), points: 11)
                Spacer()
                Button { refresh() } label: { WaitingLabel(title: list.isLoading ? "正在读取…" : "刷新", waiting: list.isLoading) }
                    .controlSize(.small).disabled(list.isLoading)
            }
            if list.isLoading {
                Text("正在读取会话列表，会话多时要几秒。").foregroundStyle(.secondary)
                Spacer()
            } else if let error = list.error {
                Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else if let session = model.agentSession {
                let groups = list.groups(current: session, open: model.agentSessions, search: search)
                if groups.isEmpty {
                    Text(search.isEmpty ? "没有会话" : "没有匹配的会话").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.title).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    ForEach(group.sessions) { item in row(item, session: session) }
                                }
                            }
                        }
                    }
                }
            } else { Spacer() }
        }
        .themedFont(.caption, points: 11)
        .padding(10)
    }

    private func row(_ item: AgentSessionList.Item, session: AgentSession) -> some View {
        let reason: String? = session.agent != .codex ? "只能查看 Codex 的会话记录" : nil
        return Button {
            model.openAgentSession(item)
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(AgentSessionList.relativeTime(item.updatedAt, now: context.date)).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(ThemeColor(token: .accent, opacity: item.id == session.sessionID ? 0.12
                                   : model.agentSessions.contains { $0.sessionID == item.id } ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .help(reason ?? (model.agentSessions.contains { $0.sessionID == item.id && !$0.restored } ? "已经开着，切到它" : "在新标签里只读查看"))
        .contextMenu {
            Button("复制会话 id") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.id, forType: .string)
            }
            Button("在终端里用 Codex 接着聊") { model.resumeInTerminal(item.id) }
            .disabled(session.agent != .codex)
        }
    }

    private func refresh() {
        guard let session = model.agentSession else { return }
        Task { await list.refresh(session: session, command: model.agentCommand(session.agent)) }
    }
}
