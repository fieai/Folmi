# Folmi：给 AI 编码助手的说明

Folmi 是一个原生 macOS 应用（SwiftUI + AppKit，macOS 14+，Apple Silicon），用来一处一处验收 Claude Code、Codex 等 AI 改的代码。底层就是 Git：收下就是暂存，不在 Git 之外另记一套状态。界面和文档都是中文。

## 目录

- `Sources/FolmiCore/`：Git 操作、差异、AI 事件、MCP 服务，不依赖界面。Git 都通过 `GitRepository`（actor）和 `GitProcess` 执行。
- `Sources/Folmi/`：App 本体。状态集中在 `FolmiModel`（`@MainActor @Observable`），按功能拆成 `FolmiModel+*.swift` 和 `*Flow.swift`。
- `Sources/FolmiHook/`：`folmi-hook`，Claude Code / Codex 的钩子程序和 MCP 入口。
- `Tests/FolmiCoreTests`、`Tests/FolmiTests`；`scripts/` 是构建、测试、发版脚本；`site/` 是官网；`docs/direction.md` 是产品方向。

## 构建和测试

```sh
swift build                          # debug 构建
./scripts/test.sh                    # 全部测试（带超时）；--filter XxxTests 只跑一部分
./scripts/build-app.sh               # 打包 dist/Folmi.app
./scripts/build-app.sh --relaunch    # 打包后退出正在运行的 Folmi（会问没保存的内容），再打开新版
./scripts/check.sh                   # 提交前的完整检查：编译、测试、性能门槛、打包
```

- **看测试结果要看全**：`test.sh` 的退出码不为 0 就是有失败。失败行的格式是 `<文件>.swift:<行>: error:`，必须在完整输出里 grep 这一行，不要只看最后几行的汇总，失败会被截掉。输出里大量的 `CoreData: error` 是系统噪音，和测试无关。
- App 的测试会真的打开窗口、读回屏幕上的内容，CI 只跑 `FolmiCoreTests`，所以 App 层的改动要在本机跑 `./scripts/test.sh`。
- 测试用 `DemoRepository.create()` 建一次性的演示仓库（`remoteUpdates: true` 会带一个本地远端和一个同事的提交），配置写在临时目录，不碰真实设置。
- 测试在 Swift 5 模式下编译，App、Core、钩子在 Swift 6 严格并发模式下编译：可能的数据竞争是编译错误。

## 代码约定

- 跟着周围的代码写：命名、注释密度、写法保持一致。注释用英文，写「为什么」；界面文字用中文。
- 改 Git 状态的操作在模型里走 `mutate` / `mutateUndoable`（忙碌状态、操作记录、执行后刷新都由它们处理）；`GitRepository` 的方法接收界面看到的快照指纹（`expectedFingerprint`），状态已经变了就拒绝执行。能撤销的要压进撤销栈（⌥⌘Z）：用户的每一步都应该能撤回。
- 不在 Git 之外另记一套状态。需要记住的东西（已看过的改动、跟踪中的评审）按内容算 key，存进项目设置（`WorkspaceStore.swift` 的 `ProjectPreferences`），新字段在 `init(from:)` 里用 `decodeIfPresent` 给默认值，旧配置要能读。
- SwiftUI 的大表达式（比如改动列表的 `List`）会让编译器报「unable to type-check in reasonable time」：把一部分拆成函数或局部 `let`，不要硬塞。
- 像素主题的字体是裁剪过的（`scripts/subset-pixel-font.py`），包含 GB2312 全部常用字和 `Sources/` 里出现的字符。用到生僻字时重新运行这个脚本。

## 产品约定

- **暂存 = 收下。** 在 Folmi 里暂存（勾选、全部暂存、按块或按行暂存）算用户收下；agent 或终端 `git add`、合并带进暂存区的改动标「没验收」，提交前要拦一次。不要写出「替用户把没看过的改动放进暂存区」的功能：撤回、挑选提交的结果放进工作区。
- 会丢东西的操作要先确认，并且能撤销。不强制推送，不替用户提交、推送。
- 访问远端只用后台取回（`git fetch`，BatchMode，不弹密码提示）和用户点的推送；检测冲突在本地用 `git merge-tree` 算，不轮询 Gerrit 之类的服务器。
- 会失败的操作，能事先判断的就事先判断：按钮置灰并写明原因，不要点了才报错（比如拿回暂放的改动前先算会不会冲突）。
- **界面用词**，统一使用：
  - 收下 / 丢弃：验收一处改动。
  - 暂存区 / 工作区。
  - 暂放 / 拿回：git stash / stash pop。不要用「收起」，「收起」只表示折叠（收起说明、收起面板）。
  - 取回：fetch；拉取：pull；推送：push。
  - 按轮次看：AI 某一轮的改动。原来的「回放」已经去掉。
- 界面文字写给不太会 Git 的人看：短句、说清楚会发生什么、能不能撤销；Git 术语能不用就不用。

## 发版和 CHANGELOG

- 用户能感知到的改动，都写进 `CHANGELOG.md` 最上面的「## 未发布」（分「新增」「改进」「修复」）。官网的更新记录和版本号由它生成。
- 改了 CHANGELOG 就运行 `python3 scripts/site-changelog.py`，重新生成 `site/index.html` 里 `<!-- changelog:start -->` 和 `<!-- version:start -->` 之间的内容；不要手改这两段，CI 会检查。
- 发版：`./scripts/ship.sh minor|patch|major|X.Y.Z`，依次检查、测试、bump（VERSION、CHANGELOG、tag）、打包签名 DMG、发布官网、推送、建 GitHub Release。`--dry-run` 先看每一步。不要手改 `VERSION`。
- 打包签名和部署脚本（`deploy.sh`、`deploy-site.py`、`deploy-dmg.py`、`beta.sh`、`release.sh` 等）在 `.gitignore` 里，只在发版的机器上，不进仓库。
- 提交说明用中文，第一行概括这次改了什么。不提交 `dist/`、`.claude/`。

## 这两个文件里由 Folmi 维护的部分

`<!-- folmi:rules -->` 和 `<!-- /folmi:rules -->` 之间的内容由 Folmi 的「越用越顺手」功能写入（用户同意过的规则），不要手改，也不要删掉标记。
