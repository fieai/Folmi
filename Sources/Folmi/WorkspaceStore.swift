import Foundation
import Darwin

struct DeliveryProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var kind: DeliveryKind
    var remote: String
    var branch: String
    var scriptPath: String
    var scriptArguments: String

    init(id: UUID = UUID(), name: String, kind: DeliveryKind, remote: String = "", branch: String = "",
         scriptPath: String = "", scriptArguments: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.remote = remote
        self.branch = branch
        self.scriptPath = scriptPath
        self.scriptArguments = scriptArguments
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, remote, branch, scriptPath, scriptArguments }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "交付配置"
        kind = try values.decodeIfPresent(DeliveryKind.self, forKey: .kind) ?? .push
        remote = try values.decodeIfPresent(String.self, forKey: .remote) ?? ""
        branch = try values.decodeIfPresent(String.self, forKey: .branch) ?? ""
        scriptPath = try values.decodeIfPresent(String.self, forKey: .scriptPath) ?? ""
        scriptArguments = try values.decodeIfPresent(String.self, forKey: .scriptArguments) ?? ""
    }
}

struct ProjectPreferences: Codable, Identifiable, Equatable {
    var id: String { rootPath }
    var rootPath: String
    var name: String
    var isDemo: Bool
    var environment: [String: String]
    var draftMessage: String
    var amendLast: Bool
    var deliveryProfiles: [DeliveryProfile]
    var selectedProfileID: UUID?
    var lastArea: String
    var editorTabs: [EditorTabState]
    var selectedEditorPath: String?
    var reviewComments: [ReviewComment] = []
    /// Names of the terminal tabs open last time ("" for a tab without a name); they reopen with the terminal.
    var terminalTabs: [String] = []
    /// Each terminal tab's working directory last time, relative to the project ("" for the project root).
    var terminalDirectories: [String] = []
    /// Review progress: content keys of the changed lines already looked at (see `ReviewProgress`).
    var reviewedLines: [String] = []
    /// The editor card's page last time (差异 / 编辑 / 全部改动 / 历史) and the change that was selected.
    var lastContent: String?
    var selectedChangePath: String?
    /// 大仓库模式 (Git's file system monitor + untracked cache for status) and whether its offer was turned down.
    var largeRepository = false
    var largeRepositoryDeclined = false
    /// Gerrit reviews pushed from here, checked against their target after each fetch (see `ReviewWatch`).
    var reviewWatches: [ReviewWatch] = []

    init(rootPath: String, name: String, isDemo: Bool = false, environment: [String: String] = [:],
         draftMessage: String = "", amendLast: Bool = false, deliveryProfiles: [DeliveryProfile] = [],
         selectedProfileID: UUID? = nil, lastArea: String = "working",
         editorTabs: [EditorTabState] = [], selectedEditorPath: String? = nil) {
        self.rootPath = rootPath
        self.name = name
        self.isDemo = isDemo
        self.environment = environment
        self.draftMessage = draftMessage
        self.amendLast = amendLast
        self.deliveryProfiles = deliveryProfiles
        self.selectedProfileID = selectedProfileID
        self.lastArea = lastArea
        self.editorTabs = editorTabs
        self.selectedEditorPath = selectedEditorPath
    }

    private enum CodingKeys: String, CodingKey {
        case rootPath, name, isDemo, environment, draftMessage, amendLast, deliveryProfiles, selectedProfileID, lastArea, editorTabs, selectedEditorPath, reviewComments, terminalTabs
        case terminalDirectories, reviewedLines, lastContent, selectedChangePath, largeRepository, largeRepositoryDeclined, reviewWatches
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try values.decode(String.self, forKey: .rootPath)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: rootPath).lastPathComponent
        isDemo = try values.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        draftMessage = try values.decodeIfPresent(String.self, forKey: .draftMessage) ?? ""
        amendLast = try values.decodeIfPresent(Bool.self, forKey: .amendLast) ?? false
        deliveryProfiles = try values.decodeIfPresent([DeliveryProfile].self, forKey: .deliveryProfiles) ?? []
        selectedProfileID = try values.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
        lastArea = try values.decodeIfPresent(String.self, forKey: .lastArea) ?? "working"
        editorTabs = try values.decodeIfPresent([EditorTabState].self, forKey: .editorTabs) ?? []
        selectedEditorPath = try values.decodeIfPresent(String.self, forKey: .selectedEditorPath)
        // Notes from a newer format are dropped rather than failing the whole file.
        reviewComments = (try? values.decodeIfPresent([ReviewComment].self, forKey: .reviewComments)) ?? []
        terminalTabs = Array(((try? values.decodeIfPresent([String].self, forKey: .terminalTabs)) ?? []).prefix(12))
        terminalDirectories = Array(((try? values.decodeIfPresent([String].self, forKey: .terminalDirectories)) ?? []).prefix(12))
        reviewedLines = Array(((try? values.decodeIfPresent([String].self, forKey: .reviewedLines)) ?? []).suffix(ReviewProgress.limit))
        lastContent = try? values.decodeIfPresent(String.self, forKey: .lastContent)
        selectedChangePath = try? values.decodeIfPresent(String.self, forKey: .selectedChangePath)
        largeRepository = (try? values.decodeIfPresent(Bool.self, forKey: .largeRepository)) ?? false
        largeRepositoryDeclined = (try? values.decodeIfPresent(Bool.self, forKey: .largeRepositoryDeclined)) ?? false
        reviewWatches = (try? values.decodeIfPresent([ReviewWatch].self, forKey: .reviewWatches)) ?? []
    }
}

struct WorkspacePreferences: Codable, Equatable {
    var version: Int = 1
    var projects: [ProjectPreferences] = []
    var selectedProjectPath: String?
    var showTerminal: Bool = false
    var editorFontSize: Double = 13
    var appearance: FolmiAppearance = .system
    var editorFontFamily: String = "JetBrains Mono"
    var editorLineHeight: Double = 22
    var editorTabSize: Int = 2
    var editorWrapLines: Bool = true
    /// The faint note after the caret's line saying who last changed it.
    var editorLineBlame: Bool = true
    var markdownOutline: Bool = true
    /// Markdown files open in the reading view (true) or the source editor.
    var markdownReading: Bool = true
    var paneLayout = PaneLayoutState()
    var theme: FolmiTheme = .standard
    /// Glass chrome (materials, edge highlights); off draws solid theme colors.
    var glassSurfaces: Bool = true
    /// Markdown diffs shown rendered (with old blocks struck through) instead of as source lines.
    var markdownDiffRendered: Bool = true
    /// Source diffs as one column (unified) instead of side by side.
    var unifiedDiff: Bool = false
    /// Hunks that only change whitespace are folded to one line (still reviewed and staged like any other).
    var foldWhitespace: Bool = false
    /// 琥珀's mascot moves (AI tab, done page); off leaves it still. The status bar mascot is always still.
    var companionMotion: Bool = true
    /// Markdown live-preview body text: "" system, "serif" system serif, or a font name.
    var markdownFontFamily: String = ""
    var markdownFontSize: Double = 16
    /// 0 means no reading-width limit.
    var markdownReadingWidth: Double = 720
    var markdownOutlineWidth: Double = 220

    private enum CodingKeys: String, CodingKey { case version, projects, selectedProjectPath, showTerminal, editorFontSize, appearance, editorFontFamily, editorLineHeight, editorTabSize, editorWrapLines, editorLineBlame, markdownOutline, paneLayout, theme, glassSurfaces, markdownFontFamily, markdownFontSize, markdownReadingWidth, markdownOutlineWidth, markdownReading, markdownDiffRendered, unifiedDiff, foldWhitespace, companionMotion }

    init(version: Int = 1, projects: [ProjectPreferences] = [], selectedProjectPath: String? = nil,
         showTerminal: Bool = false, editorFontSize: Double = 13, appearance: FolmiAppearance = .system,
         editorFontFamily: String = "JetBrains Mono", editorLineHeight: Double = 22, editorTabSize: Int = 2,
         editorWrapLines: Bool = true) {
        self.version = version
        self.projects = projects
        self.selectedProjectPath = selectedProjectPath
        self.showTerminal = showTerminal
        self.editorFontSize = editorFontSize
        self.appearance = appearance
        self.editorFontFamily = editorFontFamily
        self.editorLineHeight = editorLineHeight
        self.editorTabSize = editorTabSize
        self.editorWrapLines = editorWrapLines
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projects = try values.decodeIfPresent([ProjectPreferences].self, forKey: .projects) ?? []
        selectedProjectPath = try values.decodeIfPresent(String.self, forKey: .selectedProjectPath)
        showTerminal = try values.decodeIfPresent(Bool.self, forKey: .showTerminal) ?? false
        editorFontSize = try values.decodeIfPresent(Double.self, forKey: .editorFontSize) ?? 13
        appearance = try values.decodeIfPresent(FolmiAppearance.self, forKey: .appearance) ?? .system
        editorFontFamily = try values.decodeIfPresent(String.self, forKey: .editorFontFamily) ?? "JetBrains Mono"
        editorLineHeight = try values.decodeIfPresent(Double.self, forKey: .editorLineHeight) ?? 22
        editorTabSize = try values.decodeIfPresent(Int.self, forKey: .editorTabSize) ?? 2
        editorWrapLines = try values.decodeIfPresent(Bool.self, forKey: .editorWrapLines) ?? true
        editorLineBlame = (try? values.decodeIfPresent(Bool.self, forKey: .editorLineBlame)) ?? true
        markdownOutline = try values.decodeIfPresent(Bool.self, forKey: .markdownOutline) ?? true
        markdownReading = (try? values.decodeIfPresent(Bool.self, forKey: .markdownReading)) ?? true
        paneLayout = try values.decodeIfPresent(PaneLayoutState.self, forKey: .paneLayout) ?? PaneLayoutState()
        // An unknown theme from a newer version falls back instead of failing the whole file.
        theme = (try? values.decodeIfPresent(FolmiTheme.self, forKey: .theme)) ?? .standard
        glassSurfaces = try values.decodeIfPresent(Bool.self, forKey: .glassSurfaces) ?? true
        markdownDiffRendered = (try? values.decodeIfPresent(Bool.self, forKey: .markdownDiffRendered)) ?? true
        unifiedDiff = (try? values.decodeIfPresent(Bool.self, forKey: .unifiedDiff)) ?? false
        foldWhitespace = (try? values.decodeIfPresent(Bool.self, forKey: .foldWhitespace)) ?? false
        companionMotion = (try? values.decodeIfPresent(Bool.self, forKey: .companionMotion)) ?? true
        // Reading preferences are cosmetic: a bad value falls back instead of rejecting the file.
        let family = (try? values.decodeIfPresent(String.self, forKey: .markdownFontFamily)) ?? ""
        markdownFontFamily = family.count <= 128 && !family.contains("\0") ? family : ""
        let size = (try? values.decodeIfPresent(Double.self, forKey: .markdownFontSize)) ?? 16
        markdownFontSize = size.isFinite && (10...32).contains(size) ? size : 16
        let width = (try? values.decodeIfPresent(Double.self, forKey: .markdownReadingWidth)) ?? 720
        markdownReadingWidth = width.isFinite && (width == 0 || (400...2000).contains(width)) ? width : 720
        let outline = (try? values.decodeIfPresent(Double.self, forKey: .markdownOutlineWidth)) ?? 220
        markdownOutlineWidth = outline.isFinite ? min(MarkdownOutlineWidth.maximum, max(MarkdownOutlineWidth.minimum, outline)) : 220
    }
}

struct WorkspaceStoreFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Owns only the application's JSON file. Repository metadata and other apps' preferences are never opened.
/// Immutable (a path and limits), so it can be handed to the background queue that writes the file.
final class WorkspaceStore: Sendable {
    let url: URL
    private var manager: FileManager { .default }
    private let maximumBytes = 4 * 1_024 * 1_024

    init(url: URL) { self.url = url }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folmi", isDirectory: true)
            .appendingPathComponent("workspace.json")
    }

    func load() throws -> WorkspacePreferences {
        let destination = try checkedDestination()
        guard try existingRegularFile(at: destination) else { return WorkspacePreferences() }
        do {
            let attributes = try manager.attributesOfItem(atPath: destination.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maximumBytes else {
                throw WorkspaceStoreFailure(message: "个人配置超过 4 MiB，已停止读取；原文件未改动。")
            }
            let data = try Data(contentsOf: destination)
            let preferences = try JSONDecoder().decode(WorkspacePreferences.self, from: data)
            try validate(preferences)
            return preferences
        } catch let error as WorkspaceStoreFailure {
            throw error
        } catch {
            throw WorkspaceStoreFailure(message: "无法读取个人配置：\(error.localizedDescription)。原文件未改动，请先备份或修复 \(destination.path)。")
        }
    }

    func save(_ preferences: WorkspacePreferences) throws {
        let destination = try checkedDestination()
        try validate(preferences)
        // A damaged or newer file must never be replaced by a default state after a failed load.
        if try existingRegularFile(at: destination) { _ = try load() }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(preferences)
        } catch {
            throw WorkspaceStoreFailure(message: "无法编码个人配置：\(error.localizedDescription)")
        }
        guard data.count <= maximumBytes else {
            throw WorkspaceStoreFailure(message: "个人配置超过 4 MiB，未保存。")
        }
        try preparePrivateDirectory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".workspace-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw fileFailure("创建临时配置失败") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var closed = false
        defer {
            if !closed { try? handle.close() }
            try? manager.removeItem(at: temporary)
        }
        do {
            try handle.write(contentsOf: data)
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw fileFailure("设置配置权限失败") }
            guard Darwin.fsync(descriptor) == 0 else { throw fileFailure("写入配置失败") }
            try handle.close()
            closed = true
            // The directory is private, and the rename replaces the complete file in one operation.
            _ = try existingRegularFile(at: destination)
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw fileFailure("替换配置失败") }
        } catch let error as WorkspaceStoreFailure {
            throw error
        } catch {
            throw WorkspaceStoreFailure(message: "保存个人配置失败：\(error.localizedDescription)。请检查配置目录权限。")
        }
    }

    private func checkedDestination() throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), url.lastPathComponent != "" else {
            throw WorkspaceStoreFailure(message: "个人配置必须使用本地文件的绝对路径。")
        }
        let path = url.standardizedFileURL
        let parent = try canonicalPath(path.deletingLastPathComponent())
        let destination = parent.appendingPathComponent(path.lastPathComponent)
        let resolved = try canonicalPath(path)
        for candidate in [path, destination, resolved] {
            let components = candidate.pathComponents.map { $0.lowercased() }
            if components.contains(where: { component in
                component == ".git" || component == ".gitconfig" || component == "gitconfig" || component == ".git-credentials"
                    || component == ".smartgit" || component == "smartgit" || component.hasPrefix("smartgit ")
            }) || candidate.path.lowercased().contains("/.config/git/") || candidate.path.lowercased().hasSuffix("/git/config")
                || ["/application support/cursor/", "/application support/code/", "/.cursor/", "/.vscode/"].contains(where: { candidate.path.lowercased().contains($0) }) {
                throw WorkspaceStoreFailure(message: "个人配置路径不能位于 Git 元数据、Git 配置、SmartGit 或 Cursor / VS Code 配置中。")
            }
        }
        // Resolve parent aliases once so a private directory remains the atomic write location.
        return destination
    }

    /// Foundation can leave a symlinked parent unresolved when the final component is missing.
    /// Resolve the nearest existing ancestor first, then append only the missing suffix.
    private func canonicalPath(_ input: URL, depth: Int = 0) throws -> URL {
        guard depth < 32 else { throw WorkspaceStoreFailure(message: "个人配置路径包含过多符号链接。") }
        var ancestor = lexicallyNormalized(input)
        var missing = [String]()
        while true {
            var status = stat()
            if Darwin.lstat(ancestor.path, &status) == 0 {
                let resolved: URL
                if (status.st_mode & S_IFMT) == S_IFLNK {
                    let link = try manager.destinationOfSymbolicLink(atPath: ancestor.path)
                    let target = link.hasPrefix("/") ? URL(fileURLWithPath: link) : ancestor.deletingLastPathComponent().appendingPathComponent(link)
                    resolved = try canonicalPath(target, depth: depth + 1)
                } else {
                    guard let physical = Darwin.realpath(ancestor.path, nil) else { throw fileFailure("解析配置路径失败") }
                    resolved = URL(fileURLWithPath: String(cString: physical))
                    Darwin.free(physical)
                }
                return missing.reversed().reduce(resolved) { $0.appendingPathComponent($1) }
            }
            guard errno == ENOENT || errno == ENOTDIR else { throw fileFailure("检查配置路径失败") }
            guard ancestor.path != "/" else { throw fileFailure("无法解析配置路径") }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }

    /// URL.standardizedFileURL rewrites /private/tmp to /tmp on macOS, which can reintroduce a
    /// symlink while resolving it. Normalize dot components without changing physical prefixes.
    private func lexicallyNormalized(_ value: URL) -> URL {
        var components = [String]()
        for component in value.pathComponents where component != "/" && component != "." {
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"))
    }

    private func existingRegularFile(at destination: URL) throws -> Bool {
        var status = stat()
        if Darwin.lstat(destination.path, &status) != 0 {
            if errno == ENOENT { return false }
            throw fileFailure("检查配置文件失败")
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw WorkspaceStoreFailure(message: "个人配置必须是普通文件，不能是符号链接或目录；未读取或覆盖。")
        }
        return true
    }

    private func preparePrivateDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        let existed = manager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        if existed && !isDirectory.boolValue {
            throw WorkspaceStoreFailure(message: "个人配置的父路径不是目录。")
        }
        if !existed {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        if mode & 0o077 != 0 {
            // Do not chmod a caller's general-purpose directory such as /tmp or their home folder.
            let ownDirectory = directory.lastPathComponent == "Folmi" || directory.lastPathComponent.hasPrefix("Folmi-")
            guard !existed || ownDirectory else {
                throw WorkspaceStoreFailure(message: "个人配置需要专用私有目录（权限 0700）；未修改现有通用目录权限。")
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    private func validate(_ preferences: WorkspacePreferences) throws {
        guard preferences.version == 1 else {
            throw WorkspaceStoreFailure(message: "不支持个人配置版本 \(preferences.version)（当前支持 1）；原文件不会被覆盖。")
        }
        guard preferences.editorFontSize.isFinite, (8...40).contains(preferences.editorFontSize) else {
            throw WorkspaceStoreFailure(message: "编辑器字号必须在 8 至 40 之间。")
        }
        guard !preferences.editorFontFamily.isEmpty, preferences.editorFontFamily.count <= 128, !preferences.editorFontFamily.contains("\0"),
              preferences.editorLineHeight.isFinite, (8...80).contains(preferences.editorLineHeight),
              (1...8).contains(preferences.editorTabSize) else {
            throw WorkspaceStoreFailure(message: "编辑器字体、行高或缩进配置无效。")
        }
        var roots = Set<String>()
        for project in preferences.projects {
            guard project.rootPath.hasPrefix("/"), !project.rootPath.contains("\0") else {
                throw WorkspaceStoreFailure(message: "项目路径必须是本地绝对路径。")
            }
            let root = try canonicalPath(URL(fileURLWithPath: project.rootPath)).path
            guard roots.insert(root).inserted else {
                throw WorkspaceStoreFailure(message: "项目列表包含重复路径：\(root)")
            }
            guard project.isDemo || project.environment.isEmpty else {
                throw WorkspaceStoreFailure(message: "真实项目不持久化环境变量；请清空项目环境后保存。")
            }
            guard project.editorTabs.count <= 100 else { throw WorkspaceStoreFailure(message: "每个项目最多保存 100 个编辑标签。") }
            var tabPaths = Set<String>()
            for tab in project.editorTabs {
                guard EditorTabState.safePath(tab.path), tabPaths.insert(tab.path).inserted,
                      tab.selectionLocation >= 0, tab.selectionLength >= 0,
                      tab.scrollOffset.isFinite, tab.scrollOffset >= 0 else {
                    throw WorkspaceStoreFailure(message: "编辑标签包含不安全路径或无效光标位置。")
                }
            }
            if let path = project.selectedEditorPath {
                guard EditorTabState.safePath(path), tabPaths.contains(path) else {
                    throw WorkspaceStoreFailure(message: "选中的编辑标签不在已保存标签中。")
                }
            }
            try validateDemoEnvironment(project)
            let ids = project.deliveryProfiles.map(\.id)
            guard Set(ids).count == ids.count else {
                throw WorkspaceStoreFailure(message: "项目的交付配置包含重复标识。")
            }
        }
    }

    private func validateDemoEnvironment(_ project: ProjectPreferences) throws {
        guard !project.environment.isEmpty else { return }
        let identities: Set<String> = ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"]
        let pathKeys: Set<String> = ["HOME", "ZDOTDIR", "HISTFILE"]
        let demoParent = try canonicalPath(URL(fileURLWithPath: project.rootPath).standardizedFileURL.deletingLastPathComponent()).path
        for (key, value) in project.environment {
            let valid: Bool
            switch key {
            case "GIT_CONFIG_NOSYSTEM": valid = value == "1"
            case "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM": valid = value == "/dev/null"
            case _ where identities.contains(key): valid = !value.contains("\n") && !value.contains("\0")
            case _ where pathKeys.contains(key):
                let path = try canonicalPath(URL(fileURLWithPath: value)).path
                valid = value.hasPrefix("/") && (path.hasPrefix(demoParent + "/") || (key == "HISTFILE" && path == "/dev/null"))
            default: valid = false
            }
            guard valid else {
                throw WorkspaceStoreFailure(message: "演示项目环境包含不允许持久化的变量或值：\(key)。凭据和令牌不能写入个人配置。")
            }
        }
    }

    private func fileFailure(_ operation: String) -> WorkspaceStoreFailure {
        WorkspaceStoreFailure(message: "\(operation)：\(String(cString: strerror(errno)))。原配置未主动清空。")
    }
}
