import AppKit
import SwiftUI
import UserNotifications

/// Tells you when Claude finishes a turn while the window is in the background: a system notification that opens
/// 逐个验收 when clicked. No Dock badge: the count lives in the window, not on the icon.
@MainActor
final class AINotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AINotifier()
    weak var model: FolmiModel?
    private var asked = false

    /// UNUserNotificationCenter traps without a bundle (swift run, tests); only the packaged app uses it.
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    func start(model: FolmiModel) {
        self.model = model
        guard Self.available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Only turns that end after launch and while another app is in front; a turn read back from an old log says nothing.
    static func shouldNotify(stopped: Date, launched: Date, appActive: Bool) -> Bool {
        !appActive && stopped >= launched.addingTimeInterval(-5)
    }

    static func message(batch: AIBatch, remaining: Int?, project: String) -> (title: String, body: String) {
        let what = remaining.map { "\($0) 处等你验收" } ?? "\(batch.paths.count) 个文件等你验收"
        let prompt = batch.prompt.map { "「\($0.count > 40 ? String($0.prefix(40)) + "…" : $0)」 · " } ?? ""
        return ("\(batch.agentTitle) 改完了 · \(project)", prompt + what)
    }

    /// `opensAgent`: a click opens the AI tab at the conversation waiting, not 逐个验收.
    func post(title: String, body: String, project: String, opensAgent: Bool = false) {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        let send: @Sendable () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["project": project, "agent": opensAgent]
            let identifier = (opensAgent ? "agent-permission-" : "ai-finished-") + project
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
        if asked { send(); return }
        asked = true
        // The callback form runs on a background queue; the async form keeps this on the main actor.
        Task { if (try? await center.requestAuthorization(options: [.alert, .sound])) == true { send() } }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let project = response.notification.request.content.userInfo["project"] as? String
        let opensAgent = response.notification.request.content.userInfo["agent"] as? Bool ?? false
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let model = self.model, project == nil || model.repositoryURL?.path == project {
                if opensAgent {
                    if let waiting = model.agentSessions.first(where: \.needsPermission) { model.selectAgentSession(waiting) }
                    model.openAgentTab()
                } else {
                    model.showContent(.allChanges); model.focusPane(.editor)
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}

extension FolmiModel {
    /// Called for each turn that just ended; counts what is left to review for the notification.
    func notifyAIFinished(_ id: String) {
        guard let root = repositoryURL, let batch = aiBatches.first(where: { $0.id == id }), let stopped = batch.stopped,
              !batch.paths.isEmpty,
              AINotifier.shouldNotify(stopped: stopped, launched: PerfLog.launched, appActive: NSApp?.isActive ?? true) else { return }
        Task { [weak self] in
            guard let self else { return }
            // Same bound as the opening banner: a big change set is counted by files, not read diff by diff.
            var remaining: Int?
            if (self.snapshot?.files.count ?? 0) <= 60 {
                await self.loadAllChanges()
                guard self.repositoryURL == root else { return }
                remaining = self.reviewTally.remaining
                if remaining == 0 { return }
            }
            let text = AINotifier.message(batch: batch, remaining: remaining, project: root.lastPathComponent)
            AINotifier.shared.post(title: text.title, body: text.body, project: root.path)
        }
    }
}
