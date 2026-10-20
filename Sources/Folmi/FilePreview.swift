import AppKit
import Quartz
import SwiftUI
import WebKit

/// Files that open as a read-only preview tab instead of text: pictures in a zoomable view, and everything Quick Look
/// can show (Word, Excel, PowerPoint, PDF, audio, video) through the system's own preview.
enum FilePreviewKind: String, Sendable, Equatable {
    /// `file`: a binary nothing here can draw (an object file, an archive): what it is, how big, and where to open it.
    case image, document, file

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
                                               "ico", "icns", "svg"]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "rtf", "xls", "xlsx", "ppt", "pptx",
                                                  "pages", "numbers", "key", "odt", "ods", "odp", "epub",
                                                  "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aiff", "aif", "caf",
                                                  "ttf", "otf", "woff", "woff2", "usdz"]

    init?(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) { self = .image }
        else if Self.documentExtensions.contains(ext) { self = .document }
        else { return nil }
    }

    /// SVG is text underneath: its preview tab offers 编辑源码.
    static func hasSource(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == "svg" }

    var title: String {
        switch self {
        case .image: return "图片预览"
        case .document: return "文档预览"
        case .file: return "文件信息"
        }
    }
}

/// The preview tab's body: the picture or the Quick Look view, with a thin bar of facts and actions under it.
struct FilePreviewView: View {
    let url: URL
    let kind: FilePreviewKind
    /// Changes when the file on disk changes, so the preview reloads.
    let revision: String
    var onEditSource: (() -> Void)?
    @StateObject private var zoom = ImageZoomState()
    @Environment(\.folmiTheme) private var theme

    var body: some View {
        let _ = PerfLog.body("FilePreviewView")
        VStack(spacing: 0) {
            switch kind {
            case .image:
                ZoomableImageView(url: url, revision: revision, state: zoom)
            case .document:
                QuickLookView(url: url, revision: revision)
            case .file:
                FileInfoCard(url: url, revision: revision)
            }
            if kind != .file {
            Divider()
            HStack(spacing: 10) {
                Text(facts).themedFont(.caption.monospacedDigit(), points: 10).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if kind == .image {
                    Button("适应窗口") { zoom.fit() }.disabled(zoom.fitting)
                    Button("实际大小") { zoom.actualSize() }.disabled(abs(zoom.magnification - 1) < 0.001)
                }
                if let onEditSource { Button("编辑源码", action: onEditSource) }
                if kind != .document { Button("用默认应用打开") { NSWorkspace.shared.open(url) } }
            }
            .buttonStyle(.themedLink).themedFont(.caption, points: 10)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .folmiSurface(.navigation)
            }
        }
        .background(Color.theme(theme, \.card))
    }

    private var facts: String {
        var parts: [String] = []
        if kind == .image, let size = zoom.pixelSize {
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        parts.append(url.pathExtension.uppercased())
        if let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        if kind == .image, zoom.pixelSize != nil { parts.append("\(Int((zoom.magnification * 100).rounded()))%") }
        if kind == .image, zoom.failed { parts.append("无法读取这张图片") }
        return parts.joined(separator: " · ")
    }
}

/// A file with no preview: its icon, kind, size and date, and the ways to look at it elsewhere.
struct FileInfoCard: View {
    let url: URL
    let revision: String
    @State private var facts: [(String, String)] = []

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 72, height: 72)
            Text(url.lastPathComponent).themedFont(.headline, points: 14).lineLimit(2).multilineTextAlignment(.center)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(facts, id: \.0) { fact in
                    GridRow {
                        Text(fact.0).foregroundStyle(.secondary)
                        Text(fact.1).textSelection(.enabled)
                    }
                }
            }
            .themedFont(.caption, points: 11)
            Text("这个文件不是文本，也没有可用的预览。").themedFont(.caption, points: 11).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("快速查看") { QuickLookPreview.shared.toggle(url) }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("用默认应用打开") { NSWorkspace.shared.open(url) }
            }
            .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url.path + revision) { facts = Self.facts(url) }
    }

    static func facts(_ url: URL) -> [(String, String)] {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .contentTypeKey])
        var out: [(String, String)] = []
        out.append(("类型", values?.contentType?.localizedDescription ?? (url.pathExtension.isEmpty ? "未知" : url.pathExtension.uppercased())))
        if let size = values?.fileSize { out.append(("大小", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
        if let date = values?.contentModificationDate { out.append(("修改时间", date.formatted(date: .abbreviated, time: .shortened))) }
        return out
    }
}

/// What the image bar shows and asks for; the scroll view reports back into it.
@MainActor
final class ImageZoomState: ObservableObject {
    @Published var pixelSize: CGSize?
    @Published var magnification: Double = 1
    /// Following the window's size; pinching or 实际大小 leaves it.
    @Published var fitting = true
    @Published var failed = false
    /// SVG and PDF-backed images stay sharp at any size, so fitting may enlarge them.
    var isVector = false
    weak var scrollView: NSScrollView?

    func fit() { fitting = true; applyFit() }
    func actualSize() {
        fitting = false
        set(magnification: 1)
    }
    func applyFit() {
        guard fitting, let scrollView, let size = pixelSize, size.width > 0, size.height > 0 else { return }
        let bounds = scrollView.contentSize
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Small bitmaps stay at their own pixels; big ones shrink to fit with a little margin; vectors fill the view.
        let fit = min((bounds.width - 24) / size.width, (bounds.height - 24) / size.height)
        set(magnification: isVector ? fit : min(1, fit))
    }
    private func set(magnification value: Double) {
        guard let scrollView else { return }
        let clamped = min(scrollView.maxMagnification, max(scrollView.minMagnification, value))
        scrollView.magnification = clamped
        magnification = clamped
    }
}

/// An image in a scroll view that pinches, zooms around the pointer and keeps the picture centered when smaller than
/// the view. Transparent parts sit on a checkerboard; GIFs animate.
struct ZoomableImageView: NSViewRepresentable {
    let url: URL
    let revision: String
    let state: ImageZoomState

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 32
        let imageView = NSImageView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor(patternImage: Self.checkerboard).cgColor
        scrollView.documentView = imageView
        state.scrollView = scrollView
        context.coordinator.observe(scrollView, state: state)
        load(into: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        state.scrollView = scrollView
        if context.coordinator.loaded != url.path + revision { load(into: scrollView, coordinator: context.coordinator) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    private func load(into scrollView: NSScrollView, coordinator: Coordinator) {
        let key = url.path + revision
        coordinator.loaded = key
        let url = url, state = state
        // Decoded off the main thread; a huge bitmap is cut down to 8192 pixels on its long side, still sharp at 100%
        // for anything a screen shows. GIFs keep NSImage, which animates them.
        Task { @MainActor in
            let loaded: LoadedImage?
            if url.pathExtension.lowercased() == "gif" {
                let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
                loaded = data.flatMap(NSImage.init(data:)).map { LoadedImage(image: $0, pixelSize: Self.pixelSize(of: $0), isVector: false) }
            } else {
                loaded = await LoadedImage.load(url, maxPixels: 8_192)
            }
            guard coordinator.loaded == key, let imageView = scrollView.documentView as? NSImageView else { return }
            guard let loaded else { imageView.image = nil; state.failed = true; state.pixelSize = nil; return }
            loaded.image.size = loaded.pixelSize
            imageView.image = loaded.image
            imageView.frame = NSRect(origin: .zero, size: loaded.pixelSize)
            state.failed = false
            state.isVector = loaded.isVector
            state.pixelSize = loaded.pixelSize
            // Wait for SwiftUI to size the scroll view before fitting to it.
            DispatchQueue.main.async { state.applyFit() }
        }
    }

    /// Pixel dimensions where the file has them (a 2× screenshot shows as its real pixels), else the vector size.
    static func pixelSize(of image: NSImage) -> CGSize {
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }
        if let bitmap, bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 {
            return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        }
        let rep = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        if let rep, rep.pixelsWide > 0, rep.pixelsHigh > 0 { return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        return image.size
    }

    private static let checkerboard: NSImage = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        NSColor(white: 1, alpha: 1).setFill(); rect.fill()
        NSColor(white: 0.86, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSRect(x: 8, y: 8, width: 8, height: 8).fill()
        return true
    }

    @MainActor
    final class Coordinator: NSObject {
        var loaded = ""
        private var observers: [NSObjectProtocol] = []

        func observe(_ scrollView: NSScrollView, state: ImageZoomState) {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak state, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let state, let scrollView else { return }
                    state.fitting = false
                    state.magnification = scrollView.magnification
                }
            })
            scrollView.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak state] _ in
                MainActor.assumeIsolated { state?.applyFit() }
            })
        }

        func stop() { observers.forEach(NotificationCenter.default.removeObserver); observers = [] }
    }
}

/// Keeps a document smaller than the visible area in the middle instead of the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let frame = documentView.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}

/// The system Quick Look preview inside the tab: Office files, PDF, audio and video look as they do in Finder.
/// `scrollsWithPage`: inside a scrolling list the wheel scrolls the list until the preview is clicked, and again once
/// the pointer leaves it, so a Word page in the change list does not trap the scroll.
/// Quick Look has no public load-completion callback. Never infer failure from its private view hierarchy:
/// some valid PDF/media previews do not contain a WKWebView at all. A slow request offers dismissible help.
@MainActor
final class QuickLookLoadState: ObservableObject {
    enum Phase: Equatable { case loading, requested, help, failed(String) }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var noticeDismissed = false
    @Published var reloadID = UUID()
    private(set) var requestID = UUID()

    @discardableResult
    func begin(_ url: URL) -> UUID {
        requestID = UUID(); noticeDismissed = false
        var directory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) {
            phase = .failed("文件不存在或已被移动。")
        } else if directory.boolValue {
            phase = .failed("此路径是文件夹，无法作为文档预览。")
        } else if !FileManager.default.isReadableFile(atPath: url.path) {
            phase = .failed("当前没有读取此文件的权限。")
        } else {
            phase = .loading
        }
        return requestID
    }

    func didRequest(_ request: UUID) {
        guard request == requestID, phase == .loading else { return }
        phase = .requested
    }

    func offerHelp(_ request: UUID) {
        guard request == requestID, phase == .loading || phase == .requested else { return }
        phase = .help
    }

    func dismissNotice() { noticeDismissed = true }
}

struct QuickLookView: View {
    let url: URL
    let revision: String
    var scrollsWithPage = false
    @StateObject private var loading = QuickLookLoadState()

    var body: some View {
        VStack(spacing: 0) {
            if case let .failed(message) = loading.phase {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.exclamationmark").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("无法预览此文件").themedFont(.headline, points: 14)
                    Text(message).themedFont(.caption, points: 11).foregroundStyle(.secondary)
                    Text(url.lastPathComponent).themedFont(.caption, points: 11).textSelection(.enabled)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QuickLookSurface(url: url, revision: revision + loading.reloadID.uuidString, scrollsWithPage: scrollsWithPage)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { status; Spacer(minLength: 8); actions }
                VStack(alignment: .leading, spacing: 6) { status; actions }
            }
            .themedFont(.caption, points: 11).buttonStyle(.themedLink)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .folmiSurface(.navigation)
        }
        .task(id: url.path + revision + loading.reloadID.uuidString) {
            let request = loading.begin(url)
            do {
                try await Task.sleep(for: .milliseconds(600))
                loading.didRequest(request)
                try await Task.sleep(for: .milliseconds(7_400))
                loading.offerHelp(request)
            } catch { /* A file switch/retry cancels the old request's help. */ }
        }
    }

    @ViewBuilder private var status: some View {
        if !loading.noticeDismissed {
            HStack(spacing: 6) {
                switch loading.phase {
                case .loading:
                    ProgressView().controlSize(.mini)
                    Text("正在请求系统预览…").foregroundStyle(.secondary)
                case .requested:
                    Text("由系统快速查看提供预览").foregroundStyle(.secondary)
                case .help:
                    Text("如果内容仍为空白，可重试或在系统中打开。").foregroundStyle(.secondary)
                case .failed:
                    Text("检查文件位置和读取权限后重试。").foregroundStyle(.secondary)
                }
                if loading.phase == .help {
                    Button { loading.dismissNotice() } label: { Image(systemName: "xmark") }
                        .help("关闭预览提示").accessibilityLabel("关闭预览提示")
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("重试预览") { loading.reloadID = UUID() }
            Button("系统快速查看") { QuickLookPreview.shared.toggle(url) }
            Button("用默认应用打开") { NSWorkspace.shared.open(url) }
        }
    }
}

private struct QuickLookSurface: NSViewRepresentable {
    let url: URL
    let revision: String
    var scrollsWithPage = false

    func makeNSView(context: Context) -> QuickLookHost {
        let host = QuickLookHost(shielded: scrollsWithPage)
        host.preview.show(url, key: url.path + revision)
        return host
    }

    func updateNSView(_ host: QuickLookHost, context: Context) { host.preview.show(url, key: url.path + revision) }

    static func dismantleNSView(_ host: QuickLookHost, coordinator: ()) { host.preview.close() }
}

final class QuickLookHost: NSView {
    let preview = FittingQuickLookView(frame: .zero, style: .normal)!
    private let shield: ScrollShield?

    init(shielded: Bool) {
        shield = shielded ? ScrollShield() : nil
        super.init(frame: .zero)
        preview.shouldCloseWithWindow = false
        preview.autostarts = false
        preview.autoresizingMask = [.width, .height]
        addSubview(preview)
        if let shield { shield.autoresizingMask = [.width, .height]; addSubview(shield) }
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        preview.frame = bounds
        shield?.frame = bounds
    }
}

/// Sits over a preview in a list. Scroll events are not handled here, so they go up to the list; a click lets the
/// preview take over (to scroll the page, select text) until the pointer leaves.
final class ScrollShield: NSView {
    private var active = false
    private var tracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { active ? nil : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) {
        active = true
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        active = false
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !active else { return }
        let hint = "点一下可在预览里滚动" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white]
        let size = hint.size(withAttributes: attributes)
        let box = NSRect(x: bounds.maxX - size.width - 20, y: bounds.minY + 8, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        hint.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attributes)
    }
    override var isFlipped: Bool { false }
}

/// Quick Look lays a Word page out at its printed width (612 points for Letter) in a web view it keeps exactly that
/// wide and centred, however wide the tab is; zooming that web view only clips the page. For word-processing files the
/// web view is stretched to the full width and the page zoomed to fill it, again whenever the size changes (Quick
/// Look's own relayout narrows it back, so its frame is watched). PDF, sheets, slides and media keep Quick Look's sizing.
final class FittingQuickLookView: QLPreviewView {
    static let pageDocuments: Set<String> = ["doc", "docx", "rtf", "odt", "pages", "dotx", "docm"]
    /// About 1000 points of Letter page: as large as text gets before more width only adds empty margin.
    static let maximumZoom: CGFloat = 1.6
    private var key = ""
    private var pageWidth: CGFloat?
    private var fitting = false
    private var attempt: DispatchWorkItem?
    private weak var watched: WKWebView?
    private var frameObserver: NSObjectProtocol?

    func show(_ url: URL, key: String) {
        guard key != self.key else { return }
        self.key = key
        pageWidth = nil
        fitting = Self.pageDocuments.contains(url.pathExtension.lowercased())
        // Setting the same item again does nothing; clearing it first makes Quick Look read the file anew.
        if (previewItem as? NSURL) as URL? == url { previewItem = nil }
        previewItem = url as NSURL
        if fitting { measure(tries: 25) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitting { fit() }
    }

    override func close() {
        attempt?.cancel(); attempt = nil; fitting = false
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        super.close()
    }

    /// The page appears a moment after the item is set; look for it a few times.
    private func measure(tries: Int) {
        attempt?.cancel()
        guard tries > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.fitting, self.pageWidth == nil else { return }
            guard let web = Self.webView(in: self), !web.isLoading else { self.measure(tries: tries - 1); return }
            let key = self.key
            let script = "Math.max(0, ...Array.from(document.body ? document.body.children : []).map(e => e.scrollWidth))"
            web.evaluateJavaScript(script) { [weak self] result, _ in
                MainActor.assumeIsolated {
                    guard let self, self.key == key else { return }
                    if let width = (result as? NSNumber)?.doubleValue, width > 100 {
                        self.pageWidth = width
                        self.fit()
                    } else { self.measure(tries: tries - 1) }
                }
            }
        }
        attempt = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func fit() {
        guard fitting, let pageWidth, let web = Self.webView(in: self), let container = web.superview,
              container.bounds.width > 40 else { return }
        watch(web)
        // The page's left and right margins come along with it; 48 points of air on top of those. Past
        // `maximumZoom` the text would only get bigger, so the page stops growing and stays centred instead.
        let zoom = min(Self.maximumZoom, max(0.4, (container.bounds.width - 48) / pageWidth))
        let width = min(container.bounds.width, (pageWidth * zoom + 48).rounded())
        let frame = NSRect(x: ((container.bounds.width - width) / 2).rounded(), y: 0, width: width, height: container.bounds.height)
        if web.frame != frame { web.frame = frame }
        if abs(web.pageZoom - zoom) > 0.005 { web.pageZoom = zoom }
    }

    private func watch(_ web: WKWebView) {
        guard watched !== web else { return }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        watched = web
        web.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: web,
                                                               queue: .main) { [weak self] _ in
            // After Quick Look's layout pass, not inside it.
            MainActor.assumeIsolated { DispatchQueue.main.async { self?.fit() } }
        }
    }

    private static func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews { if let web = webView(in: child) { return web } }
        return nil
    }
}
