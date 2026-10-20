import Foundation

import AppKit

struct DemoRepository {
    /// A small generated picture for the Markdown image demo.
    static func demoPicture() -> Data? {
        let size = NSSize(width: 480, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: 20)
            let title = NSAttributedString(string: "Folmi · 图片预览", attributes: [
                .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white])
            title.draw(at: NSPoint(x: 32, y: rect.midY - 18))
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    let root: URL
    let environment: [String: String]

    /// `remoteUpdates`: main is pushed to the demo remote and tracks it, and a teammate pushes one more commit there,
    /// so the app's background fetch finds ↓1 to pull.
    static func create(includeNavigationSamples: Bool = false, remoteUpdates: Bool = false) async throws -> DemoRepository {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.appendingPathComponent("Folmi-Demo-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("repository", isDirectory: true)
        let home = parent.appendingPathComponent("home", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        let env = ["HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                   "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_AUTHOR_NAME": "Demo User", "GIT_AUTHOR_EMAIL": "demo@example.invalid",
                   "GIT_COMMITTER_NAME": "Demo User", "GIT_COMMITTER_EMAIL": "demo@example.invalid"]
        func git(_ arguments: [String]) async throws {
            _ = try await CommandRunner.git(arguments, at: root, environment: env)
        }
        try await git(["init", "-b", "main"])
        try await git(["config", "core.hooksPath", "/dev/null"])
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try manager.createDirectory(at: sources, withIntermediateDirectories: true)
        let greeting = """
        import Foundation

        struct Greeting {
            let name: String

            func message() -> String {
                "Hello, \\(name)!"
            }

            func timestamp() -> String {
                Date().description
            }

            func farewell() -> String {
                "Goodbye"
            }
        }

        """
        let readme = "# Folmi 演示\n\n这是独立临时仓库。\n\n可以在这里练习暂存、提交和本地推送。\n"
        try greeting.write(to: sources.appendingPathComponent("Greeting.swift"), atomically: true, encoding: .utf8)
        try readme.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        var baselinePaths = ["README.md", "Sources/Greeting.swift"]
        if includeNavigationSamples {
            for (path, text) in navigationSamples {
                let url = root.appendingPathComponent(path)
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                baselinePaths.append(path)
            }
            try manager.createDirectory(at: root.appendingPathComponent("scratch"), withIntermediateDirectories: true)
            let picture = root.appendingPathComponent("docs/assets/demo-picture.png")
            try manager.createDirectory(at: picture.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let png = demoPicture() { try png.write(to: picture); baselinePaths.append("docs/assets/demo-picture.png") }
        }
        try await git(["add", "--"] + baselinePaths)
        try await git(["commit", "-m", "建立演示基线"])
        try await git(["tag", "v0.1"])
        // A merged side branch, so the history page has a graph to draw. It only touches docs/.
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try manager.createDirectory(at: docs, withIntermediateDirectories: true)
        try await git(["switch", "-c", "feature/guide"])
        try "# 使用说明\n\n打开项目后，左侧是改动列表。\n".write(to: docs.appendingPathComponent("usage.md"), atomically: true, encoding: .utf8)
        try await git(["add", "--", "docs/usage.md"])
        try await git(["commit", "-m", "添加使用说明"])
        try "# 使用说明\n\n打开项目后，左侧是改动列表。\n\n⌘1/2/3 切换面板。\n".write(to: docs.appendingPathComponent("usage.md"), atomically: true, encoding: .utf8)
        try await git(["commit", "-am", "补充快捷键说明"])
        try await git(["switch", "main"])
        try manager.createDirectory(at: docs, withIntermediateDirectories: true)
        try "# 更新记录\n\n- 0.1 演示基线\n".write(to: docs.appendingPathComponent("changes.md"), atomically: true, encoding: .utf8)
        try await git(["add", "--", "docs/changes.md"])
        try await git(["commit", "-m", "添加更新记录"])
        try await git(["merge", "--no-ff", "--no-edit", "-m", "合并 feature/guide", "feature/guide"])
        let staged = readme + "\n这一行已经暂存。\n"
        try staged.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "--", "README.md"])
        try (staged + "\n这一行仍在工作区。\n").write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let changed = greeting.replacingOccurrences(of: "Hello,", with: "你好，")
            .replacingOccurrences(of: "\"Goodbye\"", with: "\"下次见\"")
        try changed.write(to: sources.appendingPathComponent("Greeting.swift"), atomically: true, encoding: .utf8)
        try "这里是尚未跟踪的笔记。\n".write(to: root.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)
        if includeNavigationSamples {
            let javascript = navigationSamples["src/app.js"]!
                .replacingOccurrences(of: "retries: 2", with: "retries: 3")
                .replacingOccurrences(of: "  return { message, enabled: false };", with: "  const labels = [\"轻量\", \"native\"];\n  return { message, labels, enabled: true };")
            try javascript.write(to: root.appendingPathComponent("src/app.js"), atomically: true, encoding: .utf8)
            let python = navigationSamples["scripts/report.py"]!
                .replacingOccurrences(of: "    total = sum(items)", with: "    valid = [item for item in items if item >= 0]\n    total = sum(valid)")
                .replacingOccurrences(of: "len(items)", with: "len(valid)")
            try python.write(to: root.appendingPathComponent("scripts/report.py"), atomically: true, encoding: .utf8)
            // A dependency file, so 逐个验收 shows a file moved to the front with its reason (依赖变动).
            try "{\n  \"name\": \"demo\",\n  \"dependencies\": { \"left-pad\": \"^1.3.0\" }\n}\n"
                .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        }
        let remote = parent.appendingPathComponent("demo-remote.git", isDirectory: true)
        try await git(["init", "--bare", remote.path])
        try await git(["remote", "add", "demo", remote.path])
        if remoteUpdates {
            try await git(["push", "--quiet", "-u", "demo", "main"])
            let teammate = parent.appendingPathComponent("teammate", isDirectory: true)
            _ = try await CommandRunner.git(["clone", "--quiet", "--branch", "main", remote.path, teammate.path], at: parent, environment: env)
            var teammateEnv = env
            teammateEnv["GIT_AUTHOR_NAME"] = "同事"; teammateEnv["GIT_COMMITTER_NAME"] = "同事"
            func other(_ arguments: [String]) async throws { _ = try await CommandRunner.git(arguments, at: teammate, environment: teammateEnv) }
            try await other(["config", "core.hooksPath", "/dev/null"])
            try "# 团队约定\n\n- 提交前先跑测试。\n- 拉取默认只快进。\n".write(to: teammate.appendingPathComponent("docs/team.md"), atomically: true, encoding: .utf8)
            try await other(["add", "--", "docs/team.md"])
            try await other(["commit", "--quiet", "-m", "添加团队约定"])
            try await other(["push", "--quiet", "origin", "main"])
            try? manager.removeItem(at: teammate)
        }
        return DemoRepository(root: root, environment: env)
    }

    private static let navigationSamples: [String: String] = [
        "src/app.js": #"""
        /* Small native demo.
           Strings and comments keep their own colors. */
        export const settings = { theme: "light", retries: 2 };

        export function greet(name) {
          const message = `Hello, ${name}!`;
          // A replacement plus an added line makes the two sides easy to compare.
          return { message, enabled: false };
        }

        console.log(greet("开发者 🌱"));

        """#,
        "scripts/report.py": #"""
        """A small report.
        This # is part of a string, not a comment.
        """
        import json

        def summarize(items):
            # Ignore negative values in the revised version.
            total = sum(items)
            return {"count": len(items), "total": total}

        if __name__ == "__main__":
            result = summarize([1, 2, -3, 4])
            print(json.dumps(result, ensure_ascii=False))

        """#,
        "config/settings.json": "{\n  \"theme\": \"system\",\n  \"terminal\": true,\n  \"fontSize\": 13,\n  \"fallback\": null\n}\n",
        "docs/formulas.md": #"""
        # 公式与图表

        行内公式 $e^{i\pi} + 1 = 0$，价格 $5 和 $10 不算公式。

        $$
        \int_0^1 x^2\,dx = \frac{1}{3}, \qquad \sum_{k=1}^{n} k = \frac{n(n+1)}{2}
        $$

        ```mermaid
        flowchart LR
          A[改动] --> B{看过了？}
          B -- 是 --> C[暂存]
          B -- 否 --> D[逐个验收]
          C --> E[提交并推送]
        ```

        公式和图表的脚本都打包在应用里，不联网；没有公式和图表的文档不会加载它们。

        """#,
        "docs/guide.md": #"""
        # Folmi

        同一份 Markdown，直接编辑，也直接阅读。

        ## 文件导航

        - **Cmd+P** 快速打开项目文件。
        - 支持 `app.js:5:3` 定位到行和列。
        - **Cmd+Shift+F** 搜索项目文字。

        > 搜索会包含打开文档的当前内容。

        ## 原位 Markdown

        点击段落开始编辑，当前段落保留源码。
        离开段落后，标题、**强调**、*斜体* 和 `行内代码` 会原位排版。

        [本地说明](../README.md) 与 ~~删除文字~~ 也保留同一份源文档。

        - [ ] 试试深色主题
        - [ ] 试试浅色主题
        - [x] 编辑和显示使用同一套字体设置

        ## 表格

        | 功能 | 快捷键 | 状态 |
        | :--- | :---: | ---: |
        | 插入表格 | ⌥⌘T | 新 |
        | 在单元格之间移动 | Tab / Shift+Tab | 新 |
        | 粗体 | ⌘B | 已有 |

        光标进入表格时显示竖线和分隔行，离开后只留网格。最后一格按 Tab 会新增一行。

        ## 图片

        ![演示图片](assets/demo-picture.png)

        粘贴截图会保存到 `assets/` 并插入链接；也可以从 Finder 拖入图片文件。右键图片可以查看原图、在 Finder 中显示或替换图片，双击图片打开原图。

        ![找不到的图片](assets/missing.png)

        上面这张图片的文件不存在：保留原链接，下面显示占位和原因。

        ## JavaScript 示例

        ```javascript
        export function greet(name) {
          const message = `Hello, ${name}!`;
          return { message, enabled: true };
        }
        ```

        ## Python 示例

        ```python
        def summarize(items):
            valid = [item for item in items if item >= 0]
            return {"count": len(valid), "total": sum(valid)}
        ```

        ## 大纲与笔记链接

        右侧大纲列出全部标题，点击跳转，当前一节会亮起。
        折叠后标题末尾显示 ⋯，点它展开。

        ⌘-点击 [[usage|使用说明]] 或 [[changes]] 打开同名笔记；[[还没写的笔记]] 会询问是否新建。
        输入 `[[` 会列出项目里的笔记名。

        ## 会话恢复

        打开几个标签，移动光标，再退出并重新打开。
        工作台保存标签顺序、当前文件、光标与滚动位置。

        未保存的文件仍由退出提示决定如何处理。

        ## 编辑快捷键

        `Cmd+D` 删除当前行，`Option+Cmd+Down` 复制当前行。
        `Shift+Option+M` 在 Markdown 原位和源码模式之间切换。

        ---

        这是独立演示仓库。所有操作只影响这份临时样例。

        """#
    ]
}
