import FolmiCore
import Foundation

/// How much a change deserves a look before the rest: 逐个验收 shows riskier files first and says why in the header.
struct ReviewRisk: Equatable {
    enum Level: Int, Comparable {
        case none, caution, high
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    var level: Level = .none
    var reasons: [String] = []

    mutating func add(_ level: Level, _ reason: String) {
        if level > self.level { self.level = level }
        if !reasons.contains(reason) { reasons.append(reason) }
    }
}

@MainActor
enum ReviewRiskRules {
    private static let manifests: Set<String> = [
        "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "package.swift", "package.resolved",
        "podfile", "podfile.lock", "cartfile", "cartfile.resolved", "requirements.txt", "pyproject.toml", "poetry.lock",
        "pipfile", "pipfile.lock", "uv.lock", "cargo.toml", "cargo.lock", "go.mod", "go.sum", "gemfile", "gemfile.lock",
        "build.gradle", "build.gradle.kts", "pom.xml", "composer.json", "composer.lock"
    ]
    private static let buildFiles: Set<String> = ["dockerfile", "makefile", "docker-compose.yml", "docker-compose.yaml", "justfile"]
    /// More removed lines than this in one file is worth a look even when nothing else stands out.
    static let bigDeletion = 80

    static func isTestPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/")
        if parts.dropLast().contains(where: { ["test", "tests", "__tests__", "spec", "specs"].contains($0) }) { return true }
        let name = String(parts.last ?? "")
        // FooTests.swift / FooTest.java: the capital T keeps contest.swift or latest.kt out.
        let original = (path as NSString).lastPathComponent
        let classStyle = ["Tests.swift", "Test.swift", "Test.java", "Tests.java", "Test.kt", "Tests.kt"].contains { original.hasSuffix($0) }
        return name.hasPrefix("test_") || name.contains("_test.") || name.contains(".test.") || name.contains(".spec.") || classStyle
    }

    /// What the path and status alone say; used to order files before their diffs are read.
    static func pathRisk(_ file: FileChange, area: ChangeArea) -> ReviewRisk {
        var risk = ReviewRisk()
        let path = file.path, lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let code = area == .staged ? file.indexCode : file.worktreeCode
        let deleted = code == "D"
        if SecretScan.isSensitivePath(path) { risk.add(.high, "密钥 / 环境文件") }
        if deleted && isTestPath(path) { risk.add(.high, "删了测试") }
        if manifests.contains(name) { risk.add(.caution, "依赖变动") }
        if lower.hasPrefix(".github/workflows/") || lower.hasPrefix(".gitlab-ci") || lower.hasPrefix(".circleci/") || buildFiles.contains(name) {
            risk.add(.caution, "构建 / CI 配置")
        }
        if lower.split(separator: "/").contains(where: { $0 == "migrations" || $0 == "migrate" }) { risk.add(.caution, "数据库迁移") }
        if deleted && !isTestPath(path) { risk.add(.caution, "删除文件") }
        return risk
    }

    private static var cache: [String: ReviewRisk] = [:]

    /// Path rules plus what the diff shows: secrets in added lines, tests losing lines, large deletions.
    static func assess(_ diff: FileDiff) -> ReviewRisk {
        let key = diff.area.rawValue + ":" + diff.file.path + ":" + diff.fingerprint + ":" + String(diff.rawPatch.count)
        if let known = cache[key] { return known }
        var risk = pathRisk(diff.file, area: diff.area)
        let counts = AllChangesNavigator.changedLines(diff)
        let added = diff.hunks.lazy.flatMap(\.lines).filter { $0.kind == .addition }.map(\.text).joined(separator: "\n")
        if !added.isEmpty, !SecretScan.findings(in: added, limit: 1).isEmpty { risk.add(.high, "疑似密钥") }
        if isTestPath(diff.file.path), counts.removed >= 10, counts.removed >= counts.added * 2 { risk.add(.high, "测试被删减") }
        if counts.removed >= bigDeletion, counts.removed > counts.added * 2 { risk.add(.caution, "大段删除 \(counts.removed) 行") }
        if cache.count > 500 { cache.removeAll() }
        cache[key] = risk
        return risk
    }

    /// Riskier first; equal risk keeps the given order (stable).
    static func ordered<T>(_ items: [T], level: (T) -> ReviewRisk.Level) -> [T] {
        items.enumerated().sorted { a, b in
            let la = level(a.element), lb = level(b.element)
            return la != lb ? la > lb : a.offset < b.offset
        }.map(\.element)
    }
}
