import AppKit
import CryptoKit
import FolmiCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ProjectIcon: Codable, Equatable {
    case image(String)
    case emoji(String)
}

struct ProjectIconCache: Sendable {
    struct Source: Codable, Equatable, Sendable {
        let path: String
        let blob: String
    }

    struct Search: Codable, Sendable {
        let source: Source?
        let date: Date
    }

    let directory: URL
    static let extensions = ["png", "jpg", "jpeg", "svg", "ico", "icns", "heic", "heif"]
    static var imageTypes: [UTType] { extensions.compactMap { UTType(filenameExtension: $0) } }

    init(workspace: URL) {
        directory = workspace.deletingLastPathComponent().appendingPathComponent("project-icons", isDirectory: true)
    }

    func autoImage(_ path: String) -> URL { directory.appendingPathComponent("auto-\(Self.key(path)).png") }
    func metadata(_ path: String) -> URL { autoImage(path).deletingPathExtension().appendingPathExtension("json") }

    func customImage(_ name: String, path: String) -> URL? {
        guard name.hasPrefix("custom-\(Self.key(path))-"), name.hasSuffix(".png"), !name.contains("/") else { return nil }
        return directory.appendingPathComponent(name)
    }

    func relocated(_ icon: ProjectIcon?, from oldPath: String, to newPath: String) throws -> ProjectIcon? {
        guard case .image(let name) = icon, oldPath != newPath else { return icon }
        guard let old = customImage(name, path: oldPath), FileManager.default.fileExists(atPath: old.path) else { return nil }
        let newName = "custom-" + Self.key(newPath) + name.dropFirst("custom-".count + Self.key(oldPath).count)
        guard let new = customImage(newName, path: newPath) else { return nil }
        try write(Data(contentsOf: old), to: new)
        return .image(newName)
    }

    func write(_ png: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
    }

    static func key(_ path: String) -> String {
        String(SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    static func abbreviation(_ name: String) -> String {
        guard let first = name.first else { return "?" }
        if !first.isASCII && first.unicodeScalars.first?.properties.name?.hasPrefix("LATIN") != true { return String(first) }
        let split = name.replacingOccurrences(of: #"(?<=[\p{Ll}\d])(?=\p{Lu})|(?<=\p{Lu})(?=\p{Lu}\p{Ll})"#,
                                              with: " ", options: .regularExpression)
        let words = split.split { $0.isWhitespace || "-_.".contains($0) }
        guard let word = words.first, let initial = word.first else { return "?" }
        if words.count > 1 { return initial.uppercased() + words[1].prefix(1).uppercased() }
        return initial.uppercased() + word.dropFirst().prefix(1).lowercased()
    }

    static func paletteIndex(_ path: String) -> Int {
        SHA256.hash(data: Data(path.utf8)).withUnsafeBytes { Int($0[0]) % 8 }
    }

    /// Read only index entries that could be icons, and keep the index blob as the cache identity.
    static func find(root: URL, name: String, environment: [String: String], cached: Source?) async throws -> (Source?, Data?) {
        let web = ["public/favicon.svg", "public/favicon.png", "public/favicon.ico", "src/app/icon.svg", "src/app/icon.png",
                   "app/icon.svg", "app/icon.png", "app/favicon.ico", "static/favicon.*"]
        let general = ["logo.svg", "logo.png", "icon.svg", "icon.png", "assets/logo.*", "assets/icon*.png", "site/assets/icon*.png", "docs/logo.*"]
        let app = "**/AppIcon.appiconset/*.png", mac = "**/*.icns", android = "android/app/src/main/res/mipmap-*/ic_launcher.png"
        let patterns = [app, mac] + web + general + [android]
        let output = try await CommandRunner.git(["ls-files", "-z", "-s", "--"] + patterns.map { ":(glob,icase)" + $0 },
                                                 at: root, environment: environment)
        let excluded: Set<String> = ["test", "fixtures", "examples", "vendor", "node_modules", ".build"]
        var groups: [String: [Source]] = [:]
        for line in output.split(separator: "\0") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let info = fields[0].split(separator: " ")
            guard info.count == 3, info[2] == "0", info[0] == "100644" || info[0] == "100755" else { continue }
            let path = String(fields[1])
            let parts = path.lowercased().split(separator: "/")
            guard parts.count <= 7, excluded.isDisjoint(with: parts.dropLast().map(String.init)),
                  AIEventStore.safeRelativePath(path, cwd: root, root: root) == path else { continue }
            let lower = path.lowercased()
            let file = (lower as NSString).lastPathComponent
            let stem = (file as NSString).deletingPathExtension
            let rule: String?
            if parts.dropLast().last == "appicon.appiconset", file.hasSuffix(".png") { rule = app }
            else if file.hasSuffix(".icns"), stem.contains("appicon") || stem == name.lowercased() || stem == root.lastPathComponent.lowercased() { rule = mac }
            else if lower.hasPrefix("android/app/src/main/res/mipmap-"), file == "ic_launcher.png" { rule = android }
            else {
                rule = (web + general).first { pattern in
                    guard pattern.contains("*") else { return lower == pattern }
                    let bounds = pattern.split(separator: "*", omittingEmptySubsequences: false)
                    return lower.hasPrefix(bounds[0]) && lower.hasSuffix(bounds[1])
                }
            }
            if let rule { groups[rule, default: []].append(Source(path: path, blob: String(info[1]))) }
        }
        for rule in patterns {
            let ranked = rule == app || rule == android
            let sources = (groups[rule] ?? []).sorted { $0.path < $1.path }
            var decoded: [(source: Source, image: NSImage, score: Int)] = []
            for source in sources {
                if !ranked, source == cached { return (source, nil) }
                guard let image = NSImage(contentsOf: root.appendingPathComponent(source.path)),
                      image.isValid, isSquareEnough(image.size) else { continue }
                let edge = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? Int(image.size.width)
                if rule == app, image.size.width != image.size.height { continue }
                if ranked {
                    decoded.append((source, image, rule == app ? abs(edge - 128) : -edge))
                } else if let png = thumbnail(image) {
                    return (source, png)
                }
            }
            for candidate in decoded.sorted(by: { $0.score < $1.score }) {
                if candidate.source == cached { return (candidate.source, nil) }
                if let png = thumbnail(candidate.image) { return (candidate.source, png) }
            }
        }
        return (nil, nil)
    }

    private static func isSquareEnough(_ size: NSSize) -> Bool {
        size.width > 0 && size.height > 0 && max(size.width, size.height) / min(size.width, size.height) <= 1.25
    }

    static func thumbnail(from url: URL) -> Data? {
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let image = NSImage(contentsOf: url) else { return nil }
        return thumbnail(image)
    }

    private static func thumbnail(_ image: NSImage) -> Data? {
        let size = image.size
        guard image.isValid, size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let scale = 128 / max(size.width, size.height)
        let width = size.width * scale, height = size.height * scale
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 128, height: 128))
        context.imageInterpolation = .high
        image.draw(in: CGRect(x: (128 - width) / 2, y: (128 - height) / 2, width: width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor @Observable
final class ProjectIcons {
    let cache: ProjectIconCache
    private(set) var automatic: [String: NSImage] = [:]
    private(set) var custom: [String: NSImage] = [:]
    @ObservationIgnored private var loaded: Set<String> = []
    @ObservationIgnored private var searches: [String: Task<Void, Never>] = [:]

    init(workspace: URL) { cache = ProjectIconCache(workspace: workspace) }

    func load(_ project: ProjectPreferences, force: Bool = false) {
        let path = project.rootPath
        if let inFlight = searches[path] {
            guard force else { return }
            inFlight.cancel()
            loaded.remove(path)
        }
        guard force || !loaded.contains(path) else { return }
        let firstLoad = loaded.insert(path).inserted
        let cache = self.cache
        searches[path] = Task { [weak self] in
            defer { if !Task.isCancelled { self?.searches[path] = nil } }
            let saved = await Task.detached(priority: .utility) {
                let metadata = (try? Data(contentsOf: cache.metadata(path))).flatMap { try? JSONDecoder().decode(ProjectIconCache.Search.self, from: $0) }
                let auto = firstLoad ? NSImage(contentsOf: cache.autoImage(path)) : nil
                var custom: NSImage?
                if firstLoad, case .image(let name) = project.customIcon, let url = cache.customImage(name, path: path) {
                    custom = NSImage(contentsOf: url)
                }
                return (metadata, auto, custom)
            }.value
            guard let self, !Task.isCancelled else { return }
            if firstLoad {
                automatic[path] = saved.1
                if custom[path] == nil { custom[path] = saved.2 }
            }
            let cached = automatic[path] == nil ? nil : saved.0?.source
            if !force, let search = saved.0, Date().timeIntervalSince(search.date) < 24 * 3600,
               search.source == nil || cached != nil { return }
            let found = await Task.detached(priority: .utility) {
                try? await ProjectIconCache.find(root: URL(fileURLWithPath: path), name: project.name,
                                                 environment: project.isDemo ? project.environment : [:], cached: cached)
            }.value
            guard !Task.isCancelled, let (source, png) = found else { return }
            do {
                if let png {
                    try cache.write(png, to: cache.autoImage(path))
                    automatic[path] = NSImage(data: png)
                } else if source == nil {
                    try? FileManager.default.removeItem(at: cache.autoImage(path))
                    automatic[path] = nil
                }
                let search = ProjectIconCache.Search(source: source, date: Date())
                try cache.write(JSONEncoder().encode(search), to: cache.metadata(path))
            } catch {
                try? FileManager.default.removeItem(at: cache.metadata(path))
                AppLog.failure("保存项目图标失败", error)
            }
        }
    }

    func removeCustom(_ icon: ProjectIcon?, path: String) {
        if case .image(let name) = icon, let url = cache.customImage(name, path: path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func remove(_ path: String, icon: ProjectIcon?) {
        searches.removeValue(forKey: path)?.cancel()
        loaded.remove(path)
        automatic[path] = nil; custom[path] = nil
        removeCustom(icon, path: path)
        for url in [cache.autoImage(path), cache.metadata(path)] { try? FileManager.default.removeItem(at: url) }
    }

    func showCustom(_ png: Data?, path: String) { custom[path] = png.flatMap { NSImage(data: $0) } }
}

extension FolmiModel {
    func chooseProjectImage(_ path: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ProjectIconCache.imageTypes
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                let png = await Task.detached(priority: .utility) { ProjectIconCache.thumbnail(from: url) }.value
                if let png { setProjectImage(png, path: path) }
                else { errorMessage = "无法读取这张图片。" }
            }
        }
    }

    func setProjectImage(_ png: Data, path: String) {
        guard projects.contains(where: { $0.rootPath == path }) else { return }
        let cache = projectIcons.cache
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let name = "custom-\(ProjectIconCache.key(path))-\(timestamp).png"
        guard let url = cache.customImage(name, path: path) else { return }
        do {
            try cache.write(png, to: url)
            if !setProjectIcon(.image(name), path: path, png: png) { try? FileManager.default.removeItem(at: url) }
        } catch { report(error, title: "保存项目图标失败") }
    }

    @discardableResult
    func setProjectIcon(_ icon: ProjectIcon?, path: String, png: Data? = nil) -> Bool {
        guard let index = projects.firstIndex(where: { $0.rootPath == path }) else { return false }
        let previous = projects[index].customIcon
        guard previous != icon else { return true }
        projects[index].customIcon = icon
        do {
            try savePreferencesNow()
            projectIcons.showCustom(png, path: path)
            projectIcons.removeCustom(previous, path: path)
            return true
        } catch {
            projects[index].customIcon = previous
            if let saved = preferences.projects.firstIndex(where: { $0.rootPath == path }) { preferences.projects[saved].customIcon = previous }
            report(error, title: "保存项目图标失败")
            return false
        }
    }
}
