import AppKit
import FolmiCore
import SwiftUI

enum GitStartupState: Equatable {
    case unchecked, checking
    case checked(GitEnvironment)

    var blocksGit: Bool {
        switch self {
        case .unchecked: return false // Models used without app startup (tests and renderers).
        case .checking: return true
        case let .checked(result): return !result.isReady
        }
    }
}

extension FolmiModel {
    /// Every app launch checks again; installation and Xcode selection can change between launches.
    func checkGitEnvironment(probe: @escaping @Sendable () -> GitEnvironment = { GitEnvironment.check() }) async {
        guard !gitCheckRunning else { return }
        gitCheckRunning = true
        gitStartupState = .checking
        gitInstallMessage = nil
        let result = await Task.detached(priority: .userInitiated, operation: probe).value
        gitStartupState = .checked(result)
        gitCheckRunning = false
        guard result.isReady else { return }
        if let link = pendingFolmiLink {
            pendingFolmiLink = nil
            startupResumed = true
            handleFolmiLink(link)
            return
        }
        guard !startupResumed else { return }
        startupResumed = true
        if CommandLine.arguments.contains("--demo"), projects.isEmpty, snapshot == nil, !busy {
            loadDemo()
        } else {
            let reader = restoresMarkdownReader
            restoreStartup()
            if reader { ReaderWebViewPool.warm() }
        }
    }

    func requestCommandLineToolsInstallation() async {
        guard !gitInstallerRunning else { return }
        gitInstallerRunning = true
        gitInstallMessage = nil
        let message = await Task.detached(priority: .userInitiated) {
            do {
                let result = try ProcessExecutor.run(executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                                                     arguments: ["--install"], directory: URL(fileURLWithPath: "/"),
                                                     environment: ProcessInfo.processInfo.environment,
                                                     timeout: 15, stdoutLimit: 64 * 1_024, stderrLimit: 64 * 1_024)
                if result.status == 0 { return "已请求系统安装。请在系统弹窗中完成安装，然后点“重新检测”。" }
                let details = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "系统未开始安装（状态码 \(result.status)）。\n\(String(details.prefix(2_000)))\n可查看下方 Apple 安装说明，完成后重新检测。"
            } catch { return "未能请求系统安装：\(error.localizedDescription)" }
        }.value
        gitInstallMessage = message
        gitInstallerRunning = false
    }
}

struct StartupEnvironmentView: View {
    let model: FolmiModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label {
                Text("准备使用 Folmi")
            } icon: {
                if let mascot = AppResources.mascot { Image(nsImage: mascot).resizable().frame(width: 28, height: 28) }
            }
            .font(.title2.weight(.semibold))
            if case .checking = model.gitStartupState {
                ProgressView("正在检查 Git 环境…")
            } else if case let .checked(result) = model.gitStartupState {
                switch result {
                case .ready:
                    Text("Git 已就绪。")
                case let .needsCommandLineTools(details):
                    Text("需要安装 Git 命令行工具").font(.headline)
                    Text("Folmi 使用 Mac 上的 Git 读取和提交改动。安装 Apple 命令行工具即可，无需安装完整 Xcode。")
                    Button("安装 Apple 命令行工具…") { Task { await model.requestCommandLineToolsInstallation() } }
                        .disabled(model.gitInstallerRunning)
                    diagnostics(details)
                case let .unavailable(details):
                    Text("Git 暂不可用").font(.headline)
                    Text("命令行工具可能已移动、尚未完成安装，或 Xcode 需要完成首次设置。请按检测详情处理后重新检测。")
                    diagnostics(details)
                }
                if let message = model.gitInstallMessage { Text(message).foregroundStyle(.secondary) }
                HStack {
                    Button("重新检测") { Task { await model.checkGitEnvironment() } }
                        .buttonStyle(.folmiProminent)
                        .disabled(model.gitInstallerRunning)
                    Button("Apple 安装说明") {
                        NSWorkspace.shared.open(URL(string: "https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/")!)
                    }
                }
                Text("AI 对话为可选功能。默认适配器需要 Node.js（含 npx）、首次联网下载及你自己的账号登录；可在设置中配置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(30)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.theme(model.theme, \.canvas))
    }

    private func diagnostics(_ details: String) -> some View {
        DisclosureGroup("检测详情") {
            ScrollView { Text(details).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 140)
        }
    }
}
