import AppKit
import FolmiCore

/// 「用 Folmi 打开」 in Finder's right-click menu (a macOS service declared as NSServices in Info.plist, message
/// `openItem`). The provider is set before launch finishes, since Finder may start the app just to deliver the
/// request; URLs that arrive before the window's model exists wait for it.
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

    @objc func openItem(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { error.pointee = "没有收到文件或文件夹。" as NSString; return }
        // Return to Finder before showing windows or presenting an error.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let model = self.model { urls.forEach { model.openFromFinder($0) } }
            else { self.pending.append(contentsOf: urls) }
        }
    }
}

extension FolmiModel {
    func handleExternalOpen(_ url: URL) {
        if url.isFileURL {
            openFromFinder(url)
        } else if url.scheme == MCPServer.scheme, url.host == "finder-open" {
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.count == 1, items[0].name == "path", let path = items[0].value,
                  path.hasPrefix("/"), !path.contains("\0") else { return }
            openFromFinder(URL(fileURLWithPath: path))
        } else {
            handleFolmiLink(url)
        }
    }

    /// Files and plain folders open independently. A folder in a work tree opens its Git project.
    func openFromFinder(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true {
            let folder = url.resolvingSymlinksInPath()
            if !folder.pathComponents.contains(where: { $0.lowercased() == ".git" }),
               let root = AIEventStore.locate(from: folder)?.root,
               let link = MCPServer.link(repository: root.path, path: nil, line: nil) {
                handleFolmiLink(link)
            } else {
                standaloneFiles.openFolder(folder, using: self)
            }
        } else {
            standaloneFiles.open(url, using: self)
        }
    }
}
