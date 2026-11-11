import AppKit

@MainActor
enum BundledTerminalCommand {
    static var executable: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/folmi")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func prompt(for command: URL) {
        let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/folmi")
        let install = NSAlert()
        install.messageText = "安装 folmi 终端命令"
        install.informativeText = "在 ~/.local/bin 创建指向这个 Folmi 的链接，之后可以从终端打开项目和文件。"
        install.addButton(withTitle: "安装")
        install.addButton(withTitle: "取消")
        guard install.runModal() == .alertFirstButtonReturn else { return }

        let result = NSAlert()
        do {
            try installLink(to: command, at: destination)
            result.messageText = "终端命令已安装"
            result.informativeText = """
                用法：folmi . 或 folmi 文件:行

                如果终端提示找不到命令，先运行：
                export PATH="$HOME/.local/bin:$PATH"
                """
        } catch {
            result.alertStyle = .warning
            result.messageText = "没能安装终端命令"
            result.informativeText = error.localizedDescription
        }
        result.runModal()
    }

    static func installLink(to command: URL, at destination: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? files.destinationOfSymbolicLink(atPath: destination.path)) == command.path { return }
        // Let creation fail if another command already owns the path.
        try files.createSymbolicLink(at: destination, withDestinationURL: command)
    }
}
