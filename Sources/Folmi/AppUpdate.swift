import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// A published Folmi release: a GitHub Release that carries the DMG and its SHA256 file (ship.sh's last step).
struct AppRelease: Equatable, Sendable {
    let version: String
    let dmgURL: URL
    let checksumURL: URL
    let pageURL: URL?
    let notes: String
}

enum AppUpdateCheck {
    static let releasesURL = URL(string: "https://api.github.com/repos/fieai/Folmi/releases?per_page=10")!
    /// Only the bundle ship.sh builds updates itself; preview builds and `swift run` never do.
    static let bundleIdentifier = "local.folmi.app"

    /// "v0.7.0" / "0.7.0" → [0, 7, 0]; anything else is not a release version.
    static func numbers(_ version: String) -> [Int]? {
        let parts = (version.hasPrefix("v") ? String(version.dropFirst()) : version).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 && parts.count == 3 ? numbers : nil
    }

    static func isNewer(_ version: String, than current: String) -> Bool {
        guard let new = numbers(version), let old = numbers(current) else { return false }
        return old.lexicographicallyPrecedes(new)
    }

    /// Every release is a pre-release (内测版), so /releases/latest would skip them all: take the highest version
    /// among those that have both files.
    static func newestRelease(from data: Data) -> AppRelease? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let releases = list.compactMap { item -> AppRelease? in
            guard item["draft"] as? Bool != true, let tag = item["tag_name"] as? String, numbers(tag) != nil else { return nil }
            let assets = (item["assets"] as? [[String: Any]] ?? []).compactMap { asset -> (String, URL)? in
                guard let name = asset["name"] as? String, let link = asset["browser_download_url"] as? String,
                      let url = URL(string: link) else { return nil }
                return (name, url)
            }
            guard let dmg = assets.first(where: { $0.0.hasSuffix(".dmg") }),
                  let checksum = assets.first(where: { $0.0 == dmg.0 + ".sha256" }) else { return nil }
            return AppRelease(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, dmgURL: dmg.1, checksumURL: checksum.1,
                              pageURL: (item["html_url"] as? String).flatMap(URL.init(string:)),
                              notes: releaseNotes(item["body"] as? String ?? ""))
        }
        return releases.max { numbers($0.version)!.lexicographicallyPrecedes(numbers($1.version)!) }
    }

    /// The release body opens with the download table and install steps; the app shows only what changed.
    static func releaseNotes(_ body: String) -> String {
        let marker = "## 这一版有什么"
        let notes = body.range(of: marker).map { String(body[$0.upperBound...]) } ?? body
        return notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A `.sha256` file is `<hex>  <file name>`.
    static func checksumMatches(_ checksumFile: String, data: Data) -> Bool {
        guard let expected = checksumFile.split(whereSeparator: \.isWhitespace).first?.lowercased(), expected.count == 64 else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected
    }
}

@MainActor
@Observable
final class AppUpdater {
    enum Phase: Equatable { case idle, checking, installing(String), installed, failed(String) }

    private(set) var available: AppRelease?
    private(set) var phase: Phase = .idle
    private(set) var lastChecked: Date?
    var showPanel = false
    let currentVersion: String?
    /// The running bundle, when it is one that may replace itself.
    let appURL: URL?
    @ObservationIgnored private var checkLoop: Task<Void, Never>?

    init(bundle: Bundle = .main) {
        currentVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        appURL = bundle.bundleURL.pathExtension == "app" && bundle.bundleIdentifier == AppUpdateCheck.bundleIdentifier ? bundle.bundleURL : nil
    }

    var enabled: Bool { appURL != nil && currentVersion != nil }

    /// Why 下载并安装 is greyed out; nil when it can run.
    var installBlocker: String? {
        guard let appURL else { return "从源码或预览版运行，不能自动更新" }
        if appURL.path.contains("/AppTranslocation/") { return "macOS 正在临时位置运行 Folmi：先把它移到「应用程序」，再打开" }
        if appURL.path.hasPrefix("/Volumes/") { return "正在从安装盘运行：先把 Folmi 拖进「应用程序」" }
        let folder = appURL.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: folder) { return "没有权限改写 \(folder)，请到官网下载新版本手动安装" }
        return nil
    }

    /// A quiet check soon after launch, then every six hours.
    func startChecking() {
        guard enabled, checkLoop == nil else { return }
        checkLoop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.check(quietly: true)
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func check(quietly: Bool = false) async {
        guard let currentVersion, phase == .idle || phase.isFailure else { return }
        phase = .checking
        do {
            var request = URLRequest(url: AppUpdateCheck.releasesURL, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Folmi/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub 暂时没有响应，稍后再试") }
            let newest = AppUpdateCheck.newestRelease(from: data)
            available = newest.flatMap { AppUpdateCheck.isNewer($0.version, than: currentVersion) ? $0 : nil }
            lastChecked = Date()
            phase = .idle
        } catch {
            // A background check that fails (offline, rate limit) keeps what it knew and says nothing.
            phase = quietly ? .idle : .failed("检查失败：\(error.localizedDescription)")
        }
    }

    /// Downloads and verifies the release, swaps it in for the running app (the old one goes to the Trash), then
    /// quits; a helper opens the new version once this process is gone.
    func install() {
        guard let release = available, let appURL, installBlocker == nil, !phase.isBusy else { return }
        phase = .installing("正在下载 \(release.version)…")
        Task {
            do {
                let (dmg, checksum) = try await Self.download(release)
                phase = .installing("正在校验并安装…")
                try await Task.detached { try Self.replace(appURL, withDMG: dmg, checksum: checksum, version: release.version) }.value
                phase = .installed
                Self.reopenAfterQuit(appURL)
                // A quit the user cancels (unsaved files) leaves the new version in place; it opens after the next quit.
                NSApp.terminate(nil)
            } catch {
                phase = .failed("更新没有完成：\(error.localizedDescription)")
            }
        }
    }

    func dismissFailure() { if phase.isFailure { phase = .idle } }

    private static func download(_ release: AppRelease) async throws -> (Data, String) {
        async let dmg = URLSession.shared.data(from: release.dmgURL)
        async let sum = URLSession.shared.data(from: release.checksumURL)
        let ((dmgData, dmgResponse), (sumData, _)) = try await (dmg, sum)
        guard (dmgResponse as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("下载失败，稍后再试") }
        return (dmgData, String(decoding: sumData, as: UTF8.self))
    }

    private nonisolated static func replace(_ appURL: URL, withDMG data: Data, checksum: String, version: String) throws {
        guard AppUpdateCheck.checksumMatches(checksum, data: data) else { throw UpdateError("下载的文件校验不一致，没有安装") }
        let files = FileManager.default
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        defer { try? files.removeItem(at: work) }
        let dmgURL = work.appendingPathComponent("Folmi.dmg")
        try data.write(to: dmgURL)
        let mount = work.appendingPathComponent("mount")
        try files.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmgURL.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        let staged = work.appendingPathComponent(appURL.lastPathComponent)
        do {
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            let source = mount.appendingPathComponent("Folmi.app")
            guard files.fileExists(atPath: source.path) else { throw UpdateError("安装包里没有 Folmi.app") }
            try run("/usr/bin/ditto", [source.path, staged.path])
        }
        try verify(staged, version: version, against: appURL)
        // The old version goes to the Trash, so this can be undone by hand; put it back if the move fails.
        var trashed: NSURL?
        try files.trashItem(at: appURL, resultingItemURL: &trashed)
        do { try files.moveItem(at: staged, to: appURL) } catch {
            if let trashed = trashed as URL? { try? files.moveItem(at: trashed, to: appURL) }
            throw error
        }
    }

    /// The new bundle must be intact, Developer ID signed by the same team as this one, and the advertised version.
    private nonisolated static func verify(_ app: URL, version: String, against current: URL) throws {
        let bundleVersion = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
        guard bundleVersion == version else { throw UpdateError("安装包的版本号（\(bundleVersion ?? "无")）和发布的 \(version) 不一致") }
        guard (try? run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])) != nil else { throw UpdateError("新版本的签名校验没有通过") }
        let signature = (try? run("/usr/bin/codesign", ["--display", "--verbose=2", app.path])) ?? ""
        guard signature.contains("Authority=Developer ID Application:") else { throw UpdateError("新版本不是 Developer ID 签名的") }
        let team = { (text: String) in text.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") } }
        let currentSignature = (try? run("/usr/bin/codesign", ["--display", "--verbose=2", current.path])) ?? ""
        if let mine = team(currentSignature), mine != "TeamIdentifier=not set", team(signature) != mine {
            throw UpdateError("新版本的签名团队和现在的不一致")
        }
    }

    private static func reopenAfterQuit(_ appURL: URL) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.3; done; /usr/bin/open \"$2\"", "sh",
                            String(ProcessInfo.processInfo.processIdentifier), appURL.path]
        AppLog.attempt("启动更新后的重新打开") { try helper.run() }
    }

    /// codesign writes --display to stderr, so both streams are returned together.
    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) 失败：\(output.prefix(200))") }
        return output
    }
}

extension AppUpdater.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
    var isBusy: Bool {
        switch self { case .checking, .installing, .installed: true; case .idle, .failed: false }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The status bar's left corner: a small button, with a dot once a newer version is out; its panel installs it.
struct UpdateStatusItem: View {
    @Bindable var updater: AppUpdater
    var body: some View {
        Button { updater.showPanel.toggle() } label: {
            Image(systemName: "arrow.down.circle")
                .overlay(alignment: .topTrailing) {
                    if updater.available != nil {
                        Circle().fill(ThemeColor(token: .accent)).frame(width: 6, height: 6).offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.pressable)
        .help(updater.available.map { "Folmi \($0.version) 可以更新了，点按查看" } ?? "Folmi \(updater.currentVersion ?? "")：检查更新")
        .accessibilityLabel(updater.available.map { "有新版本 \($0.version)" } ?? "检查更新")
        .popover(isPresented: $updater.showPanel, arrowEdge: .top) {
            UpdatePanel(updater: updater).buttonStyle(ThemedDefaultButtonStyle())
        }
    }
}

private struct UpdatePanel: View {
    let updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let release = updater.available {
                Text("Folmi \(release.version) 可以更新了").themedFont(.headline, points: 13)
                Text("现在是 \(updater.currentVersion ?? "")").foregroundStyle(.secondary)
                if !release.notes.isEmpty {
                    ScrollView { Text(release.notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 220)
                }
                Text("会下载新版本、校验签名后替换现在的 Folmi（旧版本放进废纸篓，可以找回），然后重新打开。没保存的文件会先问你。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Folmi \(updater.currentVersion ?? "")").themedFont(.headline, points: 13)
                Text(updater.lastChecked.map { "已是最新版本 · \($0.formatted(date: .omitted, time: .shortened)) 检查过" } ?? "还没检查过更新")
                    .foregroundStyle(.secondary)
            }
            status
            HStack {
                if let page = updater.available?.pageURL {
                    Button("在网页上看") { NSWorkspace.shared.open(page) }
                }
                Spacer()
                if updater.available != nil {
                    Button("下载并安装", action: updater.install)
                        .buttonStyle(.folmiProminent)
                        .disabled(updater.installBlocker != nil || updater.phase.isBusy)
                        .help(updater.installBlocker ?? "下载、安装并重新打开 Folmi")
                } else {
                    Button("检查更新") { Task { await updater.check() } }.disabled(updater.phase.isBusy)
                }
            }
            if let blocker = updater.installBlocker, updater.available != nil {
                Text(blocker).foregroundStyle(ThemeColor(token: .modified)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .themedFont(.body, points: 12)
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder private var status: some View {
        switch updater.phase {
        case .checking: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在检查…") }
        case .installing(let message): HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(message) }
        case .installed: Text("新版本已装好，退出 Folmi 后会自动打开新版本。")
        case .failed(let message):
            Text(message).foregroundStyle(ThemeColor(token: .removed)).fixedSize(horizontal: false, vertical: true)
        case .idle: EmptyView()
        }
    }
}
