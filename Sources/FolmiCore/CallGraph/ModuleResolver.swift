import Foundation

/// Turns an import's module string into a project file: relative paths, path aliases (tsconfig / jsconfig `paths`
/// and `baseUrl`, vite and webpack `alias`, the `@/` and `~/` conventions), workspace packages, and Python's
/// packages and relative imports. Whatever is not in the project is an outside package, named by its package.
struct ModuleResolver: Sendable {
    enum Target: Sendable, Equatable { case file(String), external(String) }

    private struct PathAlias: Sendable { let scope: String; let prefix: String; let suffix: String; let wildcard: Bool; let targets: [String] }
    private var files: Set<String>
    private var aliases: [PathAlias] = []
    private var baseURLs: [(scope: String, directory: String)] = []
    private var packages: [String: (directory: String, entry: String?)] = [:]
    private var packageRoots: [String] = []
    /// Folders with Python files somewhere below them: namespace packages without `__init__.py`.
    private var pythonFolders: Set<String>

    static let javaScriptExtensions = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts", "vue", "svelte"]

    /// Config files the resolver reads, by name.
    /// The same resolver with one more file, for linking an earlier version of a file that is gone now.
    func adding(_ path: String) -> ModuleResolver {
        var copy = self
        copy.files.insert(path)
        if path.hasSuffix(".py") {
            var folder = (path as NSString).deletingLastPathComponent
            while !folder.isEmpty, copy.pythonFolders.insert(folder).inserted { folder = (folder as NSString).deletingLastPathComponent }
        }
        return copy
    }

    static func isConfig(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "package.json" || (name.hasPrefix("tsconfig") && name.hasSuffix(".json")) || name == "jsconfig.json"
            || name.hasPrefix("vite.config.") || name.hasPrefix("webpack.config.") || name == "vue.config.js" || name.hasPrefix("vitest.config.")
    }

    init(files: Set<String>, configs: [String: Data]) {
        self.files = files
        var folders: Set<String> = []
        for file in files where file.hasSuffix(".py") {
            var folder = (file as NSString).deletingLastPathComponent
            while !folder.isEmpty, folders.insert(folder).inserted { folder = (folder as NSString).deletingLastPathComponent }
        }
        pythonFolders = folders
        for (path, data) in configs.sorted(by: { $0.key < $1.key }) {
            let directory = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            if name == "package.json" {
                packageRoots.append(directory)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let package = json["name"] as? String {
                    let entry = ["source", "module", "main", "types"].lazy.compactMap { json[$0] as? String }.first
                    packages[package] = (directory, entry)
                }
            } else if name.hasSuffix(".json") {
                readTSConfig(path, configs: configs, scope: directory, depth: 0)
            } else if let text = String(data: data, encoding: .utf8) {
                readBundlerAliases(text, directory: directory)
            }
        }
        // The nearest config wins: longer scopes first.
        aliases.sort { $0.scope.count != $1.scope.count ? $0.scope.count > $1.scope.count : $0.prefix.count > $1.prefix.count }
        baseURLs.sort { $0.scope.count > $1.scope.count }
        packageRoots.sort { $0.count > $1.count }
    }

    private mutating func readTSConfig(_ path: String, configs: [String: Data], scope: String, depth: Int) {
        guard depth < 4, let data = configs[path], let json = Self.jsonc(data) else { return }
        let directory = (path as NSString).deletingLastPathComponent
        if let extends = json["extends"] as? String, extends.hasPrefix(".") {
            var parent = Self.join(directory, extends)
            if !parent.hasSuffix(".json") { parent += ".json" }
            readTSConfig(parent, configs: configs, scope: scope, depth: depth + 1)
        }
        guard let options = json["compilerOptions"] as? [String: Any] else { return }
        let base = (options["baseUrl"] as? String).map { Self.join(directory, $0) }
        if let base { baseURLs.append((scope, base)) }
        if let paths = options["paths"] as? [String: [String]] {
            for (pattern, targets) in paths {
                let star = pattern.firstIndex(of: "*")
                aliases.append(PathAlias(scope: scope, prefix: star.map { String(pattern[..<$0]) } ?? pattern,
                                         suffix: star.map { String(pattern[pattern.index(after: $0)...]) } ?? "", wildcard: star != nil,
                                         targets: targets.map { Self.join(base ?? directory, $0) }))
            }
        }
    }

    /// `'@': path.resolve(__dirname, 'src')`, `'@': fileURLToPath(new URL('./src', import.meta.url))`,
    /// `{ find: '@', replacement: '/src' }`, `'@': '/src'` in a vite / webpack / vue config.
    private mutating func readBundlerAliases(_ text: String, directory: String) {
        let patterns = [
            #"['"]?([@~#$\w][\w@~#$/.-]*)['"]?\s*:\s*(?:path\.)?(?:resolve|join)\(\s*(?:__dirname|process\.cwd\(\))\s*,\s*['"]([^'"]+)['"]"#,
            #"['"]?([@~#$\w][\w@~#$/.-]*)['"]?\s*:\s*fileURLToPath\(\s*new URL\(\s*['"]([^'"]+)['"]"#,
            #"find\s*:\s*['"]([^'"]+)['"]\s*,\s*replacement\s*:\s*(?:(?:path\.)?resolve\(\s*__dirname\s*,\s*)?['"]([^'"]+)['"]"#,
            #"['"]([@~#][\w@~#$/.-]*)['"]\s*:\s*['"](\.{0,2}/[^'"]*)['"]"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let keyRange = Range(match.range(at: 1), in: text), let valueRange = Range(match.range(at: 2), in: text) else { continue }
                let key = String(text[keyRange]), value = String(text[valueRange])
                let target = value.hasPrefix("/") ? Self.join(directory, String(value.dropFirst())) : Self.join(directory, value)
                aliases.append(PathAlias(scope: directory, prefix: key + "/", suffix: "", wildcard: true, targets: [target + "/*"]))
                aliases.append(PathAlias(scope: directory, prefix: key, suffix: "", wildcard: false, targets: [target]))
            }
        }
    }

    /// JSON with comments and trailing commas, as tsconfig allows.
    static func jsonc(_ data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var out = "", inString = false, escaped = false
        var characters = Array(text), index = 0
        while index < characters.count {
            let c = characters[index]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                index += 1; continue
            }
            if c == "\"" { inString = true; out.append(c); index += 1; continue }
            if c == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }; continue
            }
            if c == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                index += 2; continue
            }
            if c == "," {
                var look = index + 1
                while look < characters.count, characters[look].isWhitespace { look += 1 }
                if look < characters.count, characters[look] == "}" || characters[look] == "]" { index += 1; continue }
            }
            out.append(c); index += 1
        }
        characters = []
        return (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
    }

    static func join(_ directory: String, _ relative: String) -> String {
        var parts = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
        for part in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }

    private static func inside(_ path: String, _ scope: String) -> Bool { scope.isEmpty || path.hasPrefix(scope + "/") }

    // MARK: JavaScript

    func resolve(_ specifier: String, from path: String, language: SourceLanguage) -> Target {
        switch language {
        case .javaScript: return resolveJavaScript(specifier, from: path)
        case .python: return resolvePython(specifier, from: path)
        }
    }

    private func javaScriptFile(_ base: String) -> String? {
        if files.contains(base) { return base }
        var stems = [base]
        // TypeScript ESM imports name the compiled file: `./util.js` is `util.ts`.
        let ext = (base as NSString).pathExtension
        if ["js", "jsx", "mjs", "cjs"].contains(ext) { stems.append((base as NSString).deletingPathExtension) }
        for stem in stems {
            for ext in Self.javaScriptExtensions where files.contains(stem + "." + ext) { return stem + "." + ext }
            for ext in Self.javaScriptExtensions where files.contains(stem + "/index." + ext) { return stem + "/index." + ext }
        }
        return nil
    }

    private func resolveJavaScript(_ specifier: String, from path: String) -> Target {
        let directory = (path as NSString).deletingLastPathComponent
        if specifier.hasPrefix(".") {
            return javaScriptFile(Self.join(directory, specifier)).map { .file($0) } ?? .external(specifier)
        }
        if specifier.hasPrefix("/") {
            let root = packageRoots.first { Self.inside(path, $0) } ?? ""
            if let file = javaScriptFile(Self.join(root, String(specifier.dropFirst()))) { return .file(file) }
        }
        for alias in aliases where Self.inside(path, alias.scope) {
            guard specifier.hasPrefix(alias.prefix), alias.wildcard || specifier == alias.prefix else { continue }
            let middle = alias.wildcard ? String(specifier.dropFirst(alias.prefix.count)) : ""
            guard middle.hasSuffix(alias.suffix) else { continue }
            let stem = String(middle.dropLast(alias.suffix.count))
            for target in alias.targets {
                let candidate = target.replacingOccurrences(of: "*", with: stem)
                if let file = javaScriptFile(candidate) { return .file(file) }
            }
        }
        for base in baseURLs where Self.inside(path, base.scope) {
            if let file = javaScriptFile(Self.join(base.directory, specifier)) { return .file(file) }
        }
        let segments = specifier.split(separator: "/").map(String.init)
        let packageName = segments.first?.hasPrefix("@") == true && segments.count > 1 ? segments[0] + "/" + segments[1] : segments.first ?? specifier
        if let package = packages[packageName] {
            let rest = segments.dropFirst(packageName.contains("/") ? 2 : 1).joined(separator: "/")
            if rest.isEmpty {
                if let entry = package.entry, let file = javaScriptFile(Self.join(package.directory, entry)) { return .file(file) }
                for stem in ["src/index", "index"] { if let file = javaScriptFile(Self.join(package.directory, stem)) { return .file(file) } }
            } else {
                for stem in [rest, "src/" + rest] { if let file = javaScriptFile(Self.join(package.directory, stem)) { return .file(file) } }
            }
        }
        // `@/x` and `~/x` mean the source folder by convention (Vue CLI, Nuxt) when no config says otherwise.
        if specifier.hasPrefix("@/") || specifier.hasPrefix("~/") {
            let root = packageRoots.first { Self.inside(path, $0) } ?? ""
            for folder in ["src", ""] {
                if let file = javaScriptFile(Self.join(Self.join(root, folder), String(specifier.dropFirst(2)))) { return .file(file) }
            }
        }
        return .external(packageName)
    }

    // MARK: Python

    /// A module's file: `a/b.py`, or `a/b/__init__.py` for a package (named so even when that file does not exist,
    /// so its submodules can still be found next to it).
    func pythonModule(_ base: String) -> String? {
        if files.contains(base + ".py") { return base + ".py" }
        if files.contains(base + ".pyi") { return base + ".pyi" }
        if files.contains(base + "/__init__.py") { return base + "/__init__.py" }
        if !base.isEmpty, pythonFolders.contains(base) { return base + "/__init__.py" }
        return nil
    }

    private func resolvePython(_ module: String, from path: String) -> Target {
        let level = module.prefix { $0 == "." }.count
        let name = String(module.dropFirst(level))
        let parts = name.split(separator: ".").map(String.init)
        if level > 0 {
            var directory = (path as NSString).deletingLastPathComponent
            for _ in 1..<max(level, 1) { directory = (directory as NSString).deletingLastPathComponent }
            let base = parts.isEmpty ? directory : Self.join(directory, parts.joined(separator: "/"))
            return pythonModule(base).map { .file($0) } ?? .external(module)
        }
        // The nearest folder above the importing file that holds the module, then the project root and `src/`.
        var directory = (path as NSString).deletingLastPathComponent
        var roots: [String] = []
        while !directory.isEmpty { roots.append(directory); directory = (directory as NSString).deletingLastPathComponent }
        roots += ["", "src"]
        let relative = parts.joined(separator: "/")
        for root in roots {
            if let file = pythonModule(Self.join(root, relative)) { return .file(file) }
        }
        return .external(parts.first ?? module)
    }
}
