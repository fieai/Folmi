# 终端持久化：退出 Folmi 后终端继续运行

状态：第一期已实现（2026-11-18）。

## 要解决什么

内嵌终端的 shell 是 Folmi 进程的子进程（SwiftTerm 的 `LocalProcessTerminalView` 持有 PTY），`TerminalSession.stop()` 还会主动发 `SIGHUP`。所以 ⌘Q、崩溃、`build-app.sh --relaunch` 升级时，终端里正在跑的 Claude Code、Codex、开发服务器全部被杀掉。项目设置里只记了标签名和目录（`terminalTabs`、`terminalDirectories`），重开只能得到新的空 shell。

目标：**关窗口、退出、升级 Folmi，终端都还在跑；再打开时接回原来的标签，能看到之前的输出。**

## 给用户的规则（界面和文档照这个写）

| 你做了什么 | 终端会怎样 |
| --- | --- |
| 关窗口、⌘Q 退出、升级重启 Folmi | 继续在后台运行。下次打开自动接回原来的标签，最近的输出还在 |
| 点标签上的 × | 结束这个终端。里面有程序在跑（不只是空 shell）时先问一次：「`npm run dev` 还在运行，关闭会结束它」 |
| 从项目轨移除项目 | 结束这个项目的所有终端（有程序在跑时一起列出来问一次） |
| 终端菜单 →「结束所有后台终端…」 | 列出数量，确认后全部结束 |
| 设置里关掉「退出 Folmi 后终端继续运行」 | 回到现在的行为：退出时结束所有终端 |
| 演示仓库 | 不进后台，随 Folmi 一起关（和现在一样） |

- 设置项默认打开。
- 第一次在有终端运行的情况下退出时，在退出前给一次说明（「终端会在后台继续运行，下次打开 Folmi 接回。要结束它们，打开 Folmi 从「终端」菜单选「结束所有后台终端」」，带「不再提示」），之后不再打扰。
- 退出 Folmi 后终端里的程序自己结束了：下次打开那个标签显示「已退出（退出码 N）」和最后的输出，和现在的「已退出」一样。

## 架构

新增一个随 App 打包的小程序 `folmi-pty`（和 `folmi-hook` 并列），负责持有所有 PTY。Folmi 通过 Unix 域套接字连上它，收发字节。

```
Folmi.app ──(unix socket: <设置目录>/run/pty.sock)── folmi-pty ──(PTY)── zsh / claude / codex / dev server
```

### 拉起和存活

- Folmi 需要开终端时连套接字；连不上就拉起 `folmi-pty serve --socket <路径>`，等它就绪（最多 2 秒），再连。
- 拉起方式：以独立的后台小 App「Folmi 终端」运行，由 LaunchServices 启动，见下面「独立的后台小 App」。启动不了时退回 `posix_spawn` 加 `POSIX_SPAWN_SETSID`。标准输入输出接 `/dev/null`，日志写到设置目录的 `run/pty.log`（滚动，最多 1 MB）。不用 launchd（不装 plist，不需要用户授权）。
- 程序文件：先把包里的小 App 复制到设置目录的 `bin/FolmiTerminal-<内容哈希前 12 位>.app` 再运行。升级替换 App 包时，正在运行的后台程序不受影响。
- 同时只允许一个：启动时对 `run/pty.lock` 加 `flock`，拿不到就退出。
- **没有会话、也没有客户端连着时，10 秒后自己退出。** 平时没有常驻进程。
- 套接字目录权限 0700，套接字 0600；每个连接用 `getpeereid` 确认是同一个用户。
- 套接字路径超过 `sun_path` 上限（104 字节，测试的临时目录可能超）时，改用 `$TMPDIR/folmi-<设置目录哈希前 12 位>.sock`，路径写进 `run/pty.path` 让 App 找到。

### 独立的后台小 App

**问题**（2026-11-18 发现）：macOS 把一个 App 和它启动的所有进程算作一个 coalition。`setsid` 只换会话和进程组，不换 coalition，所以 `folmi-pty`、所有 shell 和终端里的程序都算 Folmi 的。⌘Q 之后 Folmi 还有进程在跑，`lsappinfo` 记为 `exited-with-subordinates`，程序坞右键出现「退出后台运行」；点了它，终端里的程序（开发服务器、gitstatusd 等）全部被结束，只剩忽略 SIGTERM 的交互式 zsh。即使没有终端，Folmi 留下的 `git fsmonitor--daemon` 和 ssh 连接复用进程也会让这一项出现，用户很容易点到。

**做法**：后台服务作为单独的 App 启动。LaunchServices 启动的每个 App 都有自己的 coalition，它的子进程也留在里面（已用原型验证：`open -g -n` 启动的 `LSBackgroundOnly` App 得到独立的 coalition，参数照常传入）。这样「退出后台运行」只结束 Folmi 自己的进程，碰不到终端。

- **打包**：`Folmi.app/Contents/Library/Helpers/FolmiTerminal.app`，可执行文件就是 `folmi-pty`，代码不变。
  - `Info.plist`：`LSBackgroundOnly = true`（不进程序坞，也不进「强制退出」窗口）。bundle id 是主 App 的加 `.terminal`；显示名是主 App 名加「 终端」，正式版是「Folmi 终端」。版本号和主 App 一致。
  - 文件夹名用 ASCII；显示名会出现在系统的文件访问授权提示里，比如「“Folmi 终端”想访问“文稿”文件夹中的文件」。
- **安装**：整个小 App 按内容哈希复制到 `bin/FolmiTerminal-<哈希>.app`。哈希算可执行文件加 `Info.plist`。先复制到临时名再 `rename`，和现在一样。复制时不带 `com.apple.quarantine`（`ditto --noqtn`）：这是用户已经打开过的 Folmi 里同一份签名代码，带着隔离标记启动会再弹一次「从互联网下载」的确认。
- **启动**：`NSWorkspace.openApplication(at:configuration:)`。
  - `activates = false`、`addsToRecentItems = false`、`createsNewApplicationInstance = true`。
  - 参数 `serve --socket … --run-directory …`；`environment` 传 Folmi 自己的环境，和现在 `posix_spawn` 一样。
  - 等套接字就绪最多 3 秒（现在 2 秒）。实测：新路径第一次启动约 0.6 秒（系统登记新 App），之后约 50 毫秒；直接拉起约 6 毫秒。只有服务没在跑时才启动，接回已有终端不受影响。
  - `FolmiCore` 不依赖 AppKit：启动方式由 App 层以闭包传给 `PTYEndpoint`，Core 保留 `posix_spawn`，测试和兜底用它。
- **兜底**：LaunchServices 启动失败时退回 `posix_spawn`，终端照常可用。
- **判断是否和 Folmi 同组**：连上服务后用 `getsockopt(LOCAL_PEERPID)` 拿到服务的 pid，再用 `proc_pidinfo(PROC_PIDCOALITIONINFO)` 比较它和 Folmi 自己的 coalition。相同（兜底启动的）时，在「终端」菜单里写一行：「后台终端和 Folmi 在同一组：在程序坞里选「退出后台运行」会结束终端」。不改协议。
- **已经在跑的旧服务**：协议不变，照常连接，不迁移。它的 coalition 属于启动它的那个 Folmi；那个 Folmi 退出并且被系统收尾后，「退出后台运行」就没有对象了，所以旧服务在新版 Folmi 退出时同样安全。
- **签名**：嵌套的 App 要先作为 bundle 签名，再签外层。
  - `build-app.sh` 现在逐个签 Mach-O 文件再签外层，要在外层之前加一步签 `FolmiTerminal.app`；`codesign --verify --deep --strict` 必须通过。
  - 发版机器上的 `release.sh`、`beta.sh`（不进仓库）同样要加，并带 `--options runtime --timestamp`。
- **不选的做法**：
  - launchd（`launchctl bootstrap`、`SMAppService`）：要 plist，可能进「登录项」并弹「已添加后台项目」通知。
  - 再 fork 一次或 `setsid`：不改变 coalition。
  - 让服务忽略结束信号：保不住终端里的程序。
- **不处理**：git fsmonitor 和 ssh 连接复用进程仍会让 Folmi 显示「退出后台运行」。它们来自用户自己的 git 和 ssh 配置，被结束也没有影响。

### 协议

放在 `FolmiCore`（`PTYProtocol.swift`），编解码可以在 CI 里测。

- 帧格式：4 字节大端长度 + 1 字节类型 + 内容。控制消息的内容是 JSON，输入输出是原始字节。
- 第一条消息 `hello`：双方交换 `protocolVersion`（从 1 开始）。主版本不同时，App 不接已有会话，提示「后台终端服务是旧版本：已有的 N 个终端还在运行。重启服务会结束它们」，按钮「重启服务」（确认后）/「先不」。
- 消息：

| 方向 | 类型 | 内容 |
| --- | --- | --- |
| App → | `list` | 列出所有会话 |
| App → | `create` | `id`、`projectRoot`、`cwd`、`env`、`argv`、`cols`、`rows` |
| App → | `attach` / `detach` | `id`。attach 后先回 `replay`，再持续推 `output` |
| App → | `input` | `id` + 字节 |
| App → | `resize` | `id`、`cols`、`rows` |
| App → | `kill` | `id`：给前台进程组发 `SIGHUP`，2 秒后还在就 `SIGKILL`，关 PTY |
| App → | `shutdown` | 结束全部会话并退出（「结束所有后台终端」、测试收尾） |
| → App | `sessions` | 每个会话：`id`、`projectRoot`、`shellPid`、前台进程名（`tcgetpgrp` + `proc_name`）、是否已退出、退出码、创建时间 |
| → App | `replay` / `output` | `id` + 字节 |
| → App | `exited` | `id`、退出码 |

- 一个会话同一时间只允许一个客户端 attach（新的顶掉旧的），避免两个窗口抢尺寸。

### 输出缓冲和接回时的画面

- 每个会话保留最近 **1 MB** 原始输出（环形缓冲）。最多 32 个会话，超过时 `create` 返回错误，界面提示先关掉一些。
- 接回时 App 新建终端视图，先 `reset`，喂 `replay` 的字节，再发 `resize`。
- Claude Code、Codex 这类全屏程序用备用屏幕，光回放字节画面会错乱或不全：attach 后 `folmi-pty` **先把行数减 1 再恢复**（两次 `TIOCSWINSZ`，各发一次 `SIGWINCH`），让前台程序自己重画。普通 shell 输出靠回放就够。
- 第一期不在后台程序里跑终端模拟器，也不保存屏幕快照。

### App 这边

- `FolmiTerminalView` 现在继承 `LocalProcessTerminalView`。改成两种后端：
  - **本地进程**（现在的方式）：演示仓库、设置里关掉持久化、`folmi-pty` 拉不起来时用。
  - **后台终端**：视图继承 SwiftTerm 的 `TerminalView`，键盘输入经 `TerminalViewDelegate.send` 发 `input`，输出用 `feed(byteArray:)` 喂进去，尺寸变化发 `resize`。
- 链接悬停、⌘-点击、`outputObserver`、`onOutput`、标题（OSC 0/2）、当前目录（`currentDirectory` 用 `shellPid` 查 `proc_pidinfo`）两种后端都要照常工作。
- 拉不起后台程序时不报错打断：照旧用本地进程开终端，在终端菜单里写一行「后台终端不可用：<原因>」。
- `ProjectPreferences` 新增 `terminalSessionIDs: [String]`，和 `terminalTabs` 一一对应；`decodeIfPresent`，旧配置是空数组，对应位置当作没有会话（开新 shell，和现在一样）。
- 启动恢复：
  1. `list` 拿到所有会话。
  2. 每个保存的标签：会话还在 → attach；不在 → 在保存的目录开新 shell（现在的行为）。
  3. 后台有、但没有标签认领的会话（配置丢了、或别的设置目录留下的）：如果它的 `projectRoot` 是项目轨里的项目，就接成那个项目的新标签；否则在终端菜单里列出「N 个后台终端不属于任何已打开的项目」，可以一键结束。
- 退出时（设置打开）：只 `detach`，不 `kill`。`TerminalSession.stop()` 只在用户关标签、移除项目、关掉持久化时调用。

## 打包

- `Package.swift` 加 `executableTarget(name: "FolmiPTY", dependencies: ["FolmiCore"])`，产品名 `folmi-pty`，Swift 6 模式。
- `scripts/build-app.sh` 编译并复制到 `Contents/MacOS/folmi-pty`，`strip`；签名循环已经会签 `Contents` 下所有 Mach-O，确认它被签上。
- `check.sh` 的性能门槛：开一个终端标签的时间不能比现在明显变慢（`perf-budget.tsv` 有终端相关项就跟着比）。

## 测试

- `FolmiCoreTests`：帧编解码（半包、粘包、超长帧拒绝）；版本不匹配的处理。
- 集成测试（`FolmiTests`，临时设置目录）：拉起 `folmi-pty` → `create` 跑 `printf hello; sleep 30` → detach → 重新连接 attach，`replay` 里有 `hello` → `kill` → 收到 `exited`。
- 后台程序空闲自动退出（缩短空闲时间的测试参数）。
- **每个测试收尾都发 `shutdown`，测试结束不能留下 `folmi-pty` 进程**；`test.sh` 结束后检查一次，有残留就算失败。
- 旧配置（没有 `terminalSessionIDs`）能读，恢复时开新 shell。
- 演示仓库不连后台程序。
- 独立的后台小 App：在临时目录拼一个包着刚编译的 `folmi-pty` 的小 App（ad-hoc 签名），用 App 层的启动方式拉起，断言服务的 coalition 和测试进程不同、协议能正常创建和接回终端，最后 `shutdown`，并从 LaunchServices 注销这个临时 App（`lsregister -u`）。
- `test.sh` 的残留进程检查要同时认出两种路径：`folmi-pty-<哈希>` 和 `FolmiTerminal-<哈希>.app/Contents/MacOS/folmi-pty`。
- `build-app.sh` 打包后检查：小 App 存在、`LSBackgroundOnly` 为真、`codesign --verify --deep --strict` 通过。

## 分期

- **第一期**：上面全部（后台程序、接回、关闭规则、设置项、打包、测试）。
- **第二期**：给 [agent-overview.md](agent-overview.md) 第二期供数据（每个终端的前台进程是不是 `claude` / `codex`）；可能的话在后台程序里维护屏幕状态，接回画面更准。

## 不做

- 不依赖 tmux / screen。
- 不做远程（SSH）终端。

## 实现说明

- 后台服务通过独立进程会话持有 PTY。SwiftTerm 两种后端共用一个 `TerminalView`，本地后端直接用 SwiftTerm 的 `LocalProcess`，链接、颜色、输出观察和剪贴板策略在同一视图处理。
- 协议增加 `created`、`failure` 和 `displaced`，分别用于确认创建、报告容量等失败、通知旧连接已被接管。二进制消息以 16 字节 UUID 开头。跨主版本只允许握手和用户确认后的 `shutdown`，握手附带运行中的终端数。
- 启动时也恢复收起的标签和项目轨里未选中的项目；空项目等用户打开终端时再创建第一个标签。已退出的后台标签保留到用户关闭，仍占用 32 个会话名额之一。
- 首次退出说明默认勾选「不再提示」，确认后把选择保存在工作区设置。
- 关掉持久化后，新标签直接使用本地 shell，已经打开的后台终端会在退出 Folmi 时一起结束。后台服务创建结果不明确时保留原 ID，以便下次按 ID 查找，避免重复开 shell。
- 用改变终端尺寸的 `TIOCSWINSZ` 本身通知前台进程。缩小和恢复之间留 40 毫秒，避免两次 `SIGWINCH` 合并。重放时屏蔽终端查询的历史回复。
- 结束会话时也清理同一 PTY 会话里的后台进程组，例如在提示符后面继续跑的开发服务器。
- 没有项目认领的会话可从「终端」菜单结束。重新定位项目后，原路径上的后台终端归入未认领会话，可从同一菜单处理。
- 测试脚本用本次运行的独立设置路径识别并清理残留进程，避免影响其他工作树的并行测试和用户的实际会话。
- 独立小 App 安装时，`ditto --noqtn` 在本机仍会带上隔离属性，所以复制到临时名后用 `xattr -drs com.apple.quarantine` 递归移除，再原子改名。
- 小 App 有自己的文件访问权限，测试目录从仓库的 `.build` 移到系统临时目录，避免测试时触发「文稿」文件夹的授权提示。
- LaunchServices 启动后 3 秒内套接字没就绪、或系统报告启动失败，退回 `posix_spawn`；两个服务同时起来时，后起的拿不到 `run/pty.lock` 会自己退出。
