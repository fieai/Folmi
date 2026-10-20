import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import FolmiCore

private struct GitRepositoryKey: EnvironmentKey {
    static let defaultValue: GitRepository? = nil
}

extension EnvironmentValues {
    /// The open repository, for views that read file versions (the before / after previews of a binary change).
    var gitRepository: GitRepository? {
        get { self[GitRepositoryKey.self] }
        set { self[GitRepositoryKey.self] = newValue }
    }
}

/// One side of a change made readable by Quick Look and NSImage: the working-tree file itself, or the bytes of an
/// older version written to a temporary file that keeps the original name (so it has the right extension).
enum ChangePreviewSide: Equatable {
    case file(URL)
    case missing
    case tooLarge
    case failed(String)

    var url: URL? { if case .file(let url) = self { return url }; return nil }
}

enum ChangePreviewFiles {
    /// This app's own folder: Folmi and its preview builds can run side by side without clearing each other's files.
    /// Emptied once per launch; the system clears the temporary directory on its own too.
    static let folder: URL = {
        let name = "folmi-change-previews-" + (Bundle.main.bundleIdentifier ?? "tests")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }()

    static func load(_ version: FileVersion, path: String, repository: GitRepository) async -> ChangePreviewSide {
        do {
            if case .worktree(let relative) = version {
                // The file itself; reading it into memory is not needed.
                return try await repository.workingFileURL(relative).map(ChangePreviewSide.file) ?? .missing
            }
            guard let data = try await repository.bytes(of: version) else { return .missing }
            let name = (path as NSString).lastPathComponent
            return .file(try await Task.detached(priority: .userInitiated) { try write(data, name: name) }.value)
        } catch FolmiError.outputLimit {
            return .tooLarge
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Same bytes, same file: switching back and forth does not write again.
    nonisolated static func write(_ data: Data, name: String) throws -> URL {
        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let directory = folder.appendingPathComponent(digest, isDirectory: true)
        let url = directory.appendingPathComponent(name.isEmpty ? "file" : name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// A picture read for display: a bitmap downsampled off the main thread (a 9000-pixel TIFF does not stall the
/// window), or a vector drawn by NSImage. `pixelSize` is the file's own size, whatever was decoded.
struct LoadedImage {
    let image: NSImage
    let pixelSize: CGSize
    let isVector: Bool

    /// Longest side decoded for a preview pane.
    static let previewPixels = 2_400

    @MainActor static func load(_ url: URL, maxPixels: Int = previewPixels) async -> LoadedImage? {
        let decoded = await Task.detached(priority: .userInitiated) { () -> DecodedBitmap? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            // EXIF rotation swaps the sides the file reports; the thumbnail is already upright.
            let size = (thumbnail.width >= thumbnail.height) == (width >= height) ? CGSize(width: width, height: height)
                : CGSize(width: height, height: width)
            return DecodedBitmap(image: thumbnail, pixelSize: size)
        }.value
        if let decoded {
            return LoadedImage(image: NSImage(cgImage: decoded.image, size: decoded.pixelSize), pixelSize: decoded.pixelSize, isVector: false)
        }
        // SVG and other formats Image I/O does not read: NSImage draws them as vectors.
        guard let image = NSImage(contentsOf: url) else { return nil }
        let vector = !image.representations.contains { $0 is NSBitmapImageRep }
        return LoadedImage(image: image, pixelSize: ZoomableImageView.pixelSize(of: image), isVector: vector)
    }
}

private struct DecodedBitmap: @unchecked Sendable {
    let image: CGImage
    let pixelSize: CGSize
}

/// A picture or document change shown as itself: a new file alone, a deleted file as it was, a modified one with
/// before and after side by side (stacked in the unified layout). Pictures can also be compared by swiping or
/// overlaying; Word files by their text.
struct ChangePreview: View {
    let path: String
    let kind: FilePreviewKind
    let versions: FileVersions
    /// Changes when either side may have changed (the file on disk included), so both reload.
    let revision: String
    let oldTitle: String
    let newTitle: String
    let unified: Bool
    var height: CGFloat = ChangePreview.defaultHeight
    @Environment(\.gitRepository) private var repository
    @State private var old: ChangePreviewSide?
    @State private var new: ChangePreviewSide?
    @State private var oldImage: LoadedImage?
    @State private var newImage: LoadedImage?
    @State private var sizes: [URL: String] = [:]
    @State private var imageMode = ImageCompareMode.sideBySide
    @State private var documentMode = DocumentCompareMode.preview

    static let defaultHeight: CGFloat = 480

    enum ImageCompareMode: String, CaseIterable { case sideBySide = "并排", swipe = "滑动", overlay = "叠加" }
    enum DocumentCompareMode: String, CaseIterable { case preview = "预览", text = "文字对比" }

    private var bothSides: Bool { versions.old != nil && versions.new != nil }
    private var comparesText: Bool { kind == .document && bothSides && WordText.canRead(path) }

    var body: some View {
        let _ = PerfLog.body("ChangePreview")
        VStack(spacing: 0) {
            if bothSides && (kind == .image || comparesText) { modeBar }
            switch (versions.old, versions.new) {
            case (nil, _?):
                pane(new, image: newImage, title: "新文件 · " + newTitle, token: .added)
            case (_?, nil):
                pane(old, image: oldImage, title: "已删除 · 原来的样子", token: .removed)
            default:
                if kind == .image && imageMode != .sideBySide, let oldImage, let newImage {
                    ImageCompareView(old: oldImage, new: newImage, mode: imageMode).frame(height: height)
                } else if comparesText && documentMode == .text, let oldURL = old?.url, let newURL = new?.url {
                    WordTextDiffView(path: path, old: oldURL, new: newURL, oldTitle: oldTitle, newTitle: newTitle, unified: unified)
                } else if unified {
                    VStack(spacing: 0) {
                        pane(old, image: oldImage, title: oldTitle, token: .removed)
                        Divider()
                        pane(new, image: newImage, title: newTitle, token: .added)
                    }
                } else {
                    HStack(spacing: 0) {
                        pane(old, image: oldImage, title: oldTitle, token: .removed)
                        Divider()
                        pane(new, image: newImage, title: newTitle, token: .added)
                    }
                }
            }
        }
        .task(id: revision) { await load() }
    }

    private var modeBar: some View {
        HStack(spacing: 8) {
            if kind == .image {
                ThemedSegmented(options: ImageCompareMode.allCases.map { ($0, $0.rawValue) }, selection: $imageMode)
                    .controlSize(.small).fixedSize()
                    .help("并排：左右两张。滑动：拖动分界线看前后。叠加：调透明度看差别")
            } else {
                ThemedSegmented(options: DocumentCompareMode.allCases.map { ($0, $0.rawValue) }, selection: $documentMode)
                    .controlSize(.small).fixedSize()
                    .help("文字对比：只比较正文，按句子标出增删，看不到格式和图片的变化")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func load() async {
        guard let repository else { old = .failed("没有打开的仓库"); new = old; return }
        async let before = side(versions.old, repository)
        async let after = side(versions.new, repository)
        let (a, b) = await (before, after)
        var images: (LoadedImage?, LoadedImage?) = (nil, nil)
        if kind == .image {
            images = (await image(a.url), await image(b.url))
        }
        var described: [URL: String] = [:]
        for case .file(let url) in [a, b] {
            if let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                described[url] = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            }
        }
        old = a; new = b; oldImage = images.0; newImage = images.1; sizes = described
    }

    private func image(_ url: URL?) async -> LoadedImage? {
        guard let url else { return nil }
        return await LoadedImage.load(url)
    }

    private func side(_ version: FileVersion?, _ repository: GitRepository) async -> ChangePreviewSide {
        guard let version else { return .missing }
        return await ChangePreviewFiles.load(version, path: path, repository: repository)
    }

    private func facts(_ url: URL, image: LoadedImage?) -> String {
        var parts: [String] = []
        if let image { parts.append("\(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height))") }
        if let size = sizes[url] { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    private func pane(_ side: ChangePreviewSide?, image: LoadedImage?, title: String, token: ThemeToken) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(.themed(token, opacity: 0.65)).frame(width: 5, height: 5)
                Text(title).themedFont(.caption.weight(.medium), points: 10).lineLimit(1)
                if let url = side?.url {
                    Text(facts(url, image: image)).themedFont(.caption.monospacedDigit(), points: 10).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("用默认应用打开") { NSWorkspace.shared.open(url) }.buttonStyle(.themedLink).themedFont(.caption, points: 10)
                } else { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 10).frame(height: 28)
            Group {
                switch side {
                case nil:
                    ProgressView().controlSize(.small)
                case .file(let url)?:
                    if kind == .image {
                        if let image { FittedImage(image: image) }
                        else { Text("无法读取这张图片").themedFont(.caption, points: 10).foregroundStyle(.secondary) }
                    } else {
                        // Inside a scrolling change list: the list keeps scrolling until the preview is clicked.
                        QuickLookView(url: url, revision: revision, scrollsWithPage: true)
                    }
                case .missing?:
                    Text("这一侧没有这个文件").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                case .tooLarge?:
                    Text("文件超过 64 MiB，没有读出来预览").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                case .failed(let message)?:
                    Text("读取失败：\(message)").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

/// A picture fitted into its pane on a checkerboard, never enlarged past its own pixels (vectors may grow).
/// No scrolling of its own, so the change list around it scrolls as usual.
struct FittedImage: View {
    let image: LoadedImage

    var body: some View {
        GeometryReader { geometry in
            let fitted = Self.fit(image, in: geometry.size)
            Image(nsImage: image.image).resizable().interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .background(Checkerboard())
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    static func fit(_ image: LoadedImage, in space: CGSize, margin: CGFloat = 24) -> CGSize {
        let size = image.pixelSize
        let available = CGSize(width: max(1, space.width - margin), height: max(1, space.height - margin))
        var scale = min(available.width / max(1, size.width), available.height / max(1, size.height))
        if !image.isVector { scale = min(1, scale) }
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Before and after in one frame: drag the line to swipe between them, or fade the new one over the old.
/// Pictures of different sizes are both fitted into the box of the larger one.
struct ImageCompareView: View {
    let old: LoadedImage
    let new: LoadedImage
    let mode: ChangePreview.ImageCompareMode
    @State private var split: CGFloat = 0.5
    @State private var opacity: Double = 0.5

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let box = Self.box(old, new, in: geometry.size)
                ZStack {
                    Checkerboard().frame(width: box.width, height: box.height)
                    picture(old, in: box)
                    if mode == .swipe {
                        picture(new, in: box)
                            .mask(alignment: .leading) { Rectangle().frame(width: box.width * split) }
                        Rectangle().fill(ThemeColor(token: .accent)).frame(width: 2, height: box.height)
                            .offset(x: box.width * (split - 0.5))
                    } else {
                        picture(new, in: box).opacity(opacity)
                    }
                }
                .frame(width: box.width, height: box.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard mode == .swipe else { return }
                    split = min(1, max(0, value.location.x / max(1, box.width)))
                })
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            HStack(spacing: 8) {
                if mode == .swipe {
                    Text("左边是改后，右边是改前；拖动分界线").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                } else {
                    Text("改前").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                    Slider(value: $opacity, in: 0...1).frame(maxWidth: 220).controlSize(.small)
                    Text("改后").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 28)
        }
    }

    private func picture(_ image: LoadedImage, in box: CGSize) -> some View {
        let fitted = FittedImage.fit(image, in: box, margin: 0)
        return Image(nsImage: image.image).resizable().interpolation(.high)
            .frame(width: fitted.width, height: fitted.height)
            .frame(width: box.width, height: box.height)
    }

    /// The larger picture, fitted into the space; the smaller one is fitted into this same box.
    static func box(_ a: LoadedImage, _ b: LoadedImage, in space: CGSize) -> CGSize {
        let bigger = a.pixelSize.width * a.pixelSize.height >= b.pixelSize.width * b.pixelSize.height ? a : b
        return FittedImage.fit(bigger, in: space)
    }
}

/// The body text of a Word, RTF or OpenDocument file, one sentence per line, so a text diff points at sentences.
enum WordText {
    static func documentType(_ path: String) -> NSAttributedString.DocumentType? {
        switch (path as NSString).pathExtension.lowercased() {
        case "docx", "dotx", "docm": return .officeOpenXML
        case "doc": return .docFormat
        case "rtf": return .rtf
        case "odt": return .openDocument
        default: return nil
        }
    }
    static func canRead(_ path: String) -> Bool { documentType(path) != nil }

    static func text(of url: URL, path: String) -> String? {
        guard let type = documentType(path),
              let document = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) else { return nil }
        return sentences(document.string)
    }

    /// Paragraphs on their own lines and each sentence after its full stop on a new one; blank lines dropped.
    static func sentences(_ text: String) -> String {
        var out = ""
        for character in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") {
            if character == "\u{2028}" || character == "\u{2029}" || character == "\u{0B}" { out.append("\n"); continue }
            out.append(character)
            if "。！？；!?".contains(character) { out.append("\n") }
        }
        return out.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
    }
}

/// 文字对比 of two Word files: their sentences diffed like code, read only.
private struct WordTextDiffView: View {
    let path: String
    let old: URL
    let new: URL
    let oldTitle: String
    let newTitle: String
    let unified: Bool
    @Environment(\.gitRepository) private var repository
    @State private var diff: FileDiff?
    @State private var failure: String?

    var body: some View {
        Group {
            if let diff {
                if diff.hunks.isEmpty {
                    Text("正文文字没有变化，改的可能是格式、图片或表格样式。").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    GeometryReader { geometry in
                        SideBySideFile(
                            diff: diff, selected: [], busy: false, columnWidth: max(160, (geometry.size.width - 1) / 2),
                            onToggleLine: { _, _ in }, onApplyHunk: { _, _ in }, onApplySelection: { _, _ in },
                            onStageFile: { _ in }, onUnstageFile: { _ in }, onEditFile: { _ in },
                            comments: [], onComment: { _, _, _ in }, onDeleteComment: { _ in },
                            showsHeader: false, allowsLineSelection: false, anchorPrefix: "word#" + path + "#",
                            readOnly: true, sideTitles: (oldTitle, newTitle), unified: unified)
                    }
                    .frame(height: Self.height(of: diff, unified: unified))
                }
            } else if let failure {
                Text(failure).themedFont(.caption, points: 10).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().controlSize(.small).padding(20).frame(maxWidth: .infinity)
            }
        }
        .task(id: old.path + "\0" + new.path) { await load() }
    }

    private func load() async {
        let (old, new, path) = (old, new, path)
        let texts = await Task.detached(priority: .userInitiated) {
            (WordText.text(of: old, path: path), WordText.text(of: new, path: path))
        }.value
        guard let before = texts.0, let after = texts.1 else { failure = "读不出这个文件的正文，只能看预览。"; return }
        guard let repository else { failure = "没有打开的仓库"; return }
        do {
            diff = try await repository.contentDiff(path: path + ".txt", before: Data(before.utf8), after: Data(after.utf8))
        } catch { failure = "文字对比失败：\(error.localizedDescription)" }
    }

    /// The diff draws at its own height inside the change list (header row plus each hunk's bar and rows).
    static func height(of diff: FileDiff, unified: Bool) -> CGFloat {
        let display = SideBySideDisplayBudget.plan(for: diff)
        let rows = display.sections.reduce(0) { $0 + DiffRowsCanvas.displayCount($1.rows, unified: unified) }
        return 28 + CGFloat(display.sections.count) * 34 + DiffCanvasMetrics.height(rows: rows) + 16
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let cell: CGFloat = 8
            var path = Path()
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column) % 2 == 0 {
                    path.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(Color(white: 0.86)))
        }
    }
}
