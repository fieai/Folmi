# 终端持久化：退出 Folmi 后终端继续运行

状态：设计定稿，待实现（2026-11-18）。

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
- 第一次在有终端运行的情况下退出时，在退出前给一次说明（「终端会在后台继续运行，下次打开 Folmi 接回」，带「不再提示」），之后不再打扰。
- 退出 Folmi 后终端里的程序自己结束了：下次打开那个标签显示「已退出（退出码 N）」和最后的输出，和现在的「已退出」一样。

## 架构

新增一个随 App 打包的小程序 `folmi-pty`（和 `folmi-hook` 并列），负责持有所有 PTY。Folmi 通过 Unix 域套接字连上它，收发字节。

```
Folmi.app ──(unix socket: <设置目录>/run/pty.sock)── folmi-pty ──(PTY)── zsh / claude / codex / dev server
```

### 拉起和存活

- Folmi 需要开终端时连套接字；连不上就拉起 `folmi-pty serve --socket <路径>`，等它就绪（最多 2 秒），再连。
- 拉起方式：`posix_spawn` 加 `POSIX_SPAWN_SETSID`，标准输入输出接 `/dev/null`，日志写到设置目录的 `run/pty.log`（滚动，最多 1 MB）。这样它不在 Folmi 的进程组和会话里，Folmi 退出或崩溃它都不受影响。不用 launchd（不装 plist，不需要用户授权）。
- 程序文件：像 `folmi-hook` 一样，先把包里的 `folmi-pty` 复制到设置目录的 `bin/folmi-pty-<内容哈希前 12 位>` 再运行。升级替换 App 包时，正在运行的后台程序不受影响。
- 同时只允许一个：启动时对 `run/pty.lock` 加 `flock`，拿不到就退出。
- **没有会话、也没有客户端连着时，10 秒后自己退出。** 平时没有常驻进程。
- 套接字目录权限 0700，套接字 0600；每个连接用 `getpeereid` 确认是同一个用户。
- 套接字路径超过 `sun_path` 上限（104 字节，测试的临时目录可能超）时，改用 `$TMPDIR/folmi-<设置目录哈希前 12 位>.sock`，路径写进 `run/pty.path` 让 App 找到。

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

## 分期

- **第一期**：上面全部（后台程序、接回、关闭规则、设置项、打包、测试）。
- **第二期**：给 [agent-overview.md](agent-overview.md) 第二期供数据（每个终端的前台进程是不是 `claude` / `codex`）；可能的话在后台程序里维护屏幕状态，接回画面更准。

## 不做

- 不依赖 tmux / screen。
- 不做远程（SSH）终端。
