import AppKit
import FolmiCore

/// 「用 Folmi 打开」 in Finder's right-click menu (a macOS service declared as NSServices in Info.plist, message
/// `openFolder`). The provider is set before launch finishes, since Finder may start the app just to deliver the
/// request; folders that arrive before the window's model exists wait for it.
@MainActor
final class FinderService: NSObject {
    static let shared = FinderService()
    private weak var model: FolmiModel?
    private var pending: [URL] = []

    /// Called from applicationWillFinishLaunching. Also asks the system to re-read the app's services, so a freshly
    /// installed or moved copy shows up in Finder without logging out.
    func install() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func attach(_ model: FolmiModel) {
        self.model = model
        let waiting = pending
        pending = []
        for url in waiting { model.openFromFinder(url) }
    }

    @objc func openFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let url = urls.first else { error.pointee = "没有收到文件夹。" as NSString; return }
        if let model { model.openFromFinder(url) } else { pending.append(url) }
    }
}

extension FolmiModel {
    /// A folder from Finder (right-click service, a folder dropped on the Dock icon, `open -a Folmi <dir>`): opens the
    /// Git project it belongs to, or switches to it when it is already in the list.
    func openFromFinder(_ url: URL) {
        NSApp?.activate(ignoringOtherApps: true)
        guard let root = AIEventStore.locate(from: url)?.root else { reportNotRepository(url); return }
        guard let link = MCPServer.link(repository: root.path, path: "", line: nil) else { return }
        Task { [weak self] in
            // At launch the last project may still be loading; opening waits for it instead of being dropped.
            for _ in 0..<150 {
                guard let self else { return }
                if !self.busy { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.handleFolmiLink(link)
        }
    }
}
