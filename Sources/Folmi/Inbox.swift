import AppKit
import Carbon.HIToolbox
import SwiftUI

/// ⌃⌥⌘I from anywhere: one line into the project's inbox.md, to hand to Claude later. Uses a Carbon hot key, which
/// needs no accessibility permission.
@MainActor
final class InboxPanel {
    static let shared = InboxPanel()
    private var panel: NSPanel?
    private var hotKey: EventHotKeyRef?
    private weak var model: FolmiModel?

    func register(model: FolmiModel) {
        self.model = model
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { InboxPanel.shared.show(model: nil) } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5742_4958), id: 1) // "WBIX"
        RegisterEventHotKey(UInt32(kVK_ANSI_I), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func show(model: FolmiModel?) {
        if let model { self.model = model }
        guard let model = self.model else { return }
        guard let root = model.repositoryURL ?? model.projects.first.map({ URL(fileURLWithPath: $0.rootPath) }) else { NSSound.beep(); return }
        panel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.contentView = NSHostingView(rootView: InboxField(project: (root.path as NSString).lastPathComponent) { [weak self] text in
            if let text { self?.append(text, root: root) }
            self?.panel?.close(); self?.panel = nil
        })
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    private func append(_ text: String, root: URL) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let url = root.appendingPathComponent("inbox.md")
        let stamp = Date().formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Inbox\n\n随手记下的需求，攒够了交给 Claude。\n\n"
        if !existing.hasSuffix("\n") { existing += "\n" }
        do { try (existing + "- [ ] \(line)（\(stamp)）\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { model?.report(error, title: "写入 inbox.md 失败") }
        model?.record("随手记", "\(url.path)\n\(line)")
    }
}

private struct InboxField: View {
    let project: String
    let onDone: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down").foregroundStyle(ThemeColor(token: .accent))
            TextField("随手记一条，⏎ 写进 \(project)/inbox.md，Esc 取消", text: $text)
                .textFieldStyle(.plain).themedFont(.system(size: 16), points: 16).focused($focused)
                .onSubmit { onDone(text) }
                .onExitCommand { onDone(nil) }
        }
        .padding(.horizontal, 18).frame(width: 520, height: 64)
        .onAppear { focused = true }
    }
}
