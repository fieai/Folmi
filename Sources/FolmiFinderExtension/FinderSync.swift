import AppKit
import FinderSync
import OSLog

@objc(FolmiFinderSync)
final class FolmiFinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    private let logger = Logger(subsystem: "local.folmi.finder", category: "open")
    private var extensionBundle: Bundle { Bundle(for: FolmiFinderSync.self) }

    override init() {
        super.init()
        controller.directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForSidebar,
              selectedURL != nil else { return nil }
        let menu = NSMenu()
        let title = extensionBundle.object(forInfoDictionaryKey: "FolmiOpenMenuTitle") as? String ?? "用 Folmi 打开"
        let item = NSMenuItem(title: title, action: #selector(openInFolmi), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    private var selectedURL: URL? {
        if let selection = controller.selectedItemURLs(), !selection.isEmpty {
            return selection.count == 1 ? selection.first : nil
        }
        return controller.targetedURL()
    }

    @objc private func openInFolmi() {
        guard let url = selectedURL, url.isFileURL else { return }
        // A sandboxed Finder extension does not necessarily have read access to the selected file.
        // Hand the path to the containing app as a URL event; that app opens the file itself.
        let app = extensionBundle.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var request = URLComponents()
        request.scheme = "folmi"
        request.host = "finder-open"
        request.queryItems = [URLQueryItem(name: "path", value: url.path)]
        guard let request = request.url else { return }
        NSWorkspace.shared.open([request], withApplicationAt: app, configuration: .init()) { [logger] _, error in
            if let error {
                let failure = error as NSError
                logger.error("Could not open in Folmi: \(failure.domain, privacy: .public) \(failure.code)")
            }
        }
    }
}
