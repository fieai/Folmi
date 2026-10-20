import AppKit
import Foundation

/// Local images for Markdown: resolving the pictures a document links to (the reader shows them), and saving pasted or
/// dropped images next to it. Only files inside the project are read; nothing is fetched from the network.
enum MarkdownImageLimits {
    /// Larger files are not shown.
    static let maximumBytes = 32 * 1_024 * 1_024
}

extension EditorWorkspace {
    nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "svg"]

    /// The project file an image target in `documentPath` points to, or nil for web addresses, missing files and
    /// anything that leaves the project.
    func imageURL(_ target: String, from documentPath: String) -> URL? {
        guard case let .file(path, _, _) = MarkdownLinks.resolve(target, from: documentPath),
              Self.imageExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path), contains(url) else { return nil }
        return url
    }

    /// True when `url`, with its links resolved, is inside the project.
    private func contains(_ url: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return (url.resolvingSymlinksInPath().standardizedFileURL.path + "/").hasPrefix(base)
    }

    /// Saves pasted image data as `assets/<document>-<time>.png` beside the document and returns the link to it.
    func saveImageAsset(_ data: Data, extension pathExtension: String = "png", for documentPath: String, date: Date = Date()) throws -> String {
        let documentDirectory = (documentPath as NSString).deletingLastPathComponent
        guard contains(root.appendingPathComponent(documentDirectory, isDirectory: true)) else { throw FileEditorError.unsafePath }
        let folder = root.appendingPathComponent(documentDirectory, isDirectory: true).appendingPathComponent("assets", isDirectory: true)
        // The folder may already exist as a link to somewhere else; never write through it.
        if let type = try? FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw FileEditorError.symbolicLink
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard contains(folder) else { throw FileEditorError.unsafePath }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = Self.fileStem(((documentPath as NSString).lastPathComponent as NSString).deletingPathExtension)
        let base = "\(stem)-\(formatter.string(from: date))"
        for attempt in 1...99 {
            let name = (attempt == 1 ? base : "\(base)-\(attempt)") + "." + pathExtension
            let url = folder.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try data.write(to: url, options: .withoutOverwriting) } catch { throw FileEditorError.io(error.localizedDescription) }
            return "assets/" + Self.encodeLink(name)
        }
        throw FileEditorError.io("assets 里同名图片太多")
    }

    /// A link from `documentPath` to an image file: a relative path when the file is in the project,
    /// otherwise a copy saved under `assets/`.
    func imageLink(for file: URL, from documentPath: String) throws -> String {
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        if resolved.path.hasPrefix(base) {
            let target = String(resolved.path.dropFirst(base.count)).split(separator: "/").map(String.init)
            var from = documentPath.split(separator: "/").dropLast().map(String.init)
            var to = target
            while let first = from.first, let other = to.first, first == other, to.count > 1 { from.removeFirst(); to.removeFirst() }
            return (Array(repeating: "..", count: from.count) + to).map(Self.encodeLink).joined(separator: "/")
        }
        let data: Data
        do { data = try Data(contentsOf: resolved) } catch { throw FileEditorError.io(error.localizedDescription) }
        guard data.count <= MarkdownImageLimits.maximumBytes else { throw FileEditorError.tooLarge }
        let pathExtension = resolved.pathExtension.lowercased()
        return try saveImageAsset(data, extension: pathExtension.isEmpty ? "png" : pathExtension, for: documentPath)
    }

    /// The Markdown for pasted or dropped images: one `![name](link)` line per file, or the saved picture.
    /// Nil, with the error shown, when nothing could be linked.
    func imageMarkdown(files: [URL], png: Data?, for documentPath: String) -> String? {
        do {
            if !files.isEmpty {
                return try files.map { "![\(($0.lastPathComponent as NSString).deletingPathExtension)](\(try imageLink(for: $0, from: documentPath)))" }
                    .joined(separator: "\n")
            }
            guard let png else { return nil }
            return "![](\(try saveImageAsset(png, for: documentPath)))"
        } catch {
            errorMessage = "图片没有插入：\(error.localizedDescription)"
            return nil
        }
    }

    /// Letters of any script, digits, `-` and `_`; everything else becomes `-`.
    static func fileStem(_ name: String) -> String {
        let stem = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return stem.isEmpty ? "image" : stem
    }

    /// Spaces and parentheses would end a Markdown link address, so they are percent-encoded.
    static func encodeLink(_ component: String) -> String {
        component.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }
}

enum MarkdownImageSource {
    /// The address inside a standalone image line such as `![alt](assets/a.png "title")` or `![](<a b.png>)`,
    /// without angle brackets or title; nil when the line holds no image.
    static func targetRange(in text: String, line: NSRange) -> NSRange? {
        let source = text as NSString
        guard NSMaxRange(line) <= source.length else { return nil }
        let content = source.substring(with: line) as NSString
        let open = content.range(of: "![")
        guard open.location != NSNotFound else { return nil }
        var depth = 0, cursor = open.location + 1, labelEnd = -1
        while cursor < content.length {
            let unit = content.character(at: cursor)
            if unit == 92 { cursor += 2; continue }
            if unit == 91 { depth += 1 } else if unit == 93 { depth -= 1; if depth == 0 { labelEnd = cursor; break } }
            cursor += 1
        }
        guard labelEnd >= 0, labelEnd + 1 < content.length, content.character(at: labelEnd + 1) == 40 else { return nil }
        var start = labelEnd + 2
        while start < content.length, [32, 9].contains(content.character(at: start)) { start += 1 }
        guard start < content.length else { return nil }
        if content.character(at: start) == 60 {
            let close = content.range(of: ">", range: NSRange(location: start, length: content.length - start))
            guard close.location != NSNotFound else { return nil }
            return NSRange(location: line.location + start + 1, length: close.location - start - 1)
        }
        var end = start, parens = 0
        while end < content.length {
            let unit = content.character(at: end)
            if unit == 32 || unit == 9 { break }
            if unit == 40 { parens += 1 } else if unit == 41 { if parens == 0 { break }; parens -= 1 }
            end += 1
        }
        return end > start ? NSRange(location: line.location + start, length: end - start) : nil
    }
}

extension NSPasteboard {
    /// Image files on the pasteboard (copied in Finder or dragged in), in order.
    var markdownImageFiles: [URL] {
        let urls = readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { EditorWorkspace.imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// PNG data of a pasted picture (a screenshot, an image copied from an app), or nil when there is text to paste.
    var markdownImagePNG: Data? {
        if let string = string(forType: .string), !string.isEmpty { return nil }
        if let png = data(forType: .png) { return png }
        guard let tiff = data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
