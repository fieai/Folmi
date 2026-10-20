# Folmi

AI 一轮能改几十个文件，人很难一处处看完。Folmi 是一个 macOS 原生应用，帮你看清 Claude Code、Codex 改了什么：先看要紧的，看不懂的当场问，一处一处决定留不留，每一步都能撤回。

![Folmi 主界面](site/assets/shot-graphite-light.jpg)

- 官网与下载：<https://folmi.mindmesh.site>（目前是内测版）
- 系统要求：macOS 14 及以上，Apple Silicon
- 产品方向与取舍：[docs/direction.md](docs/direction.md)

## 它能做什么

**看 AI 的改动**

- 逐个验收：空格看下一处，⏎ 收下，⌫ 丢弃，⌥⌘Z 撤销。收下就是暂存，没处理的留在工作区，不在 Git 之外另记一套状态。
- 要紧的排前面：依赖、构建脚本、配置、大段删除先给你看，并写明为什么值得先看。
- 左右对照的差异视图、全部改动连续滚动、按行或按块暂存，可以在改动旁写评论，再一次发给终端里的 agent。
- 选中一段，让 AI 解释这处改动，回答就显示在改动旁边。

**配合 Claude Code 和 Codex**

- 钩子：按轮次记录 AI 的改动，顶部显示「正在修改 / 改完了」；一整轮可以整批撤回，也能回放；可选拦截 `git push`、`git reset --hard` 这类危险命令。
- MCP 服务（`folmi-hook mcp`）：agent 能读到你写的审阅评论，处理完标成「已处理」，也能在 Folmi 里打开指定文件和行。
- 你反复丢弃的改动会归纳成规则提议，同意后写进 `CLAUDE.md` / `AGENTS.md`，可以随时查看和删除。
- 其他 AI 改的文件也能看、收、丢，只是不按轮次接入。

**读和改 Markdown**

- 阅读视图支持公式（KaTeX）和 Mermaid，还能渲染差异、显示大纲、查看文档历史。
- 源码编辑辅助：表格里按 Tab 跳格、`/` 菜单、粘贴图片、`[[` 补全。

**Git 和日常**

- 提交前检查，后台预先写好提交说明；推送、拉取和冲突处理、分支、历史与提交图、收起改动（stash）、大仓库模式。
- 内嵌多标签终端（SwiftTerm）、⌘K 命令面板、⌘P 快速打开、全文搜索、多项目、四套主题。

## 从源码构建

需要 Xcode 16 或更高版本（Swift 6 工具链）。

```sh
swift build
./scripts/test.sh
```

打包成 App 并用演示仓库试用（使用隔离配置，不会碰你的真实项目和个人设置）：

```sh
./scripts/build-app.sh --editor-preview
open -n dist/Folmi-EditorPreview.app --args --demo --workspace-file /tmp/Folmi-Demo/workspace.json
```

`./scripts/build-app.sh` 不带参数时生成 `dist/Folmi.app`。有 Apple Development 证书时用它签名，否则做 ad-hoc 签名，只适合在本机运行。

交付前完整检查（编译、测试、性能门槛、打包）：

```sh
./scripts/check.sh            # SKIP_PERF=1 可跳过性能门槛
```

签名、公证和发布用的脚本没有放进公开仓库。

## 目录

| 路径 | 内容 |
| --- | --- |
| `Sources/Folmi` | App 本体（SwiftUI / AppKit） |
| `Sources/FolmiCore` | Git 操作、差异、AI 事件、MCP 服务，不依赖界面 |
| `Sources/FolmiHook` | `folmi-hook`：Claude Code / Codex 的钩子程序和 MCP 服务入口 |
| `Tests/` | `FolmiCoreTests` 与 `FolmiTests` |
| `scripts/` | 构建、测试、性能、打包、发布脚本 |
| `site/` | 宣传页 |
| `docs/` | 产品方向、设计说明、品牌资源、验收记录 |

## 数据放在哪里

- 个人设置：`~/Library/Application Support/Folmi/`（目录权限 0700，文件 0600）。
- AI 的改动记录、审阅评论和决定：放在各项目的 `.git/folmi/` 里，不进提交。
- 钩子只在你点「接入」时写进项目的 `.claude/settings.local.json` 或 `.codex/hooks.json`。MCP 也只在你确认后才注册到 Claude Code、Claude 桌面 App 或 Codex 的配置里。
- AI 的 API Key 存在系统钥匙串里。只有你配置了模型服务时，才会向该服务发请求。

## 第三方组件

| 组件 | 用途 | 许可 |
| --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.19.0 | 内嵌终端 | MIT |
| [KaTeX](https://katex.org) | Markdown 公式 | MIT，见 [licenses/](licenses/) |
| [Mermaid](https://mermaid.js.org) | Markdown 图表 | MIT，见 [licenses/](licenses/) |
| [Fusion Pixel](https://github.com/TakWolf/fusion-pixel-font) | 像素主题字体 | OFL-1.1，见 [licenses/FusionPixel](licenses/FusionPixel) |
| One Dark Pro 配色 | 编辑器主题 | MIT，见 [licenses/](licenses/) |

KaTeX、Mermaid 和字体都打包在 App 里，运行时不联网加载。

## 许可证

[MIT](LICENSE)
