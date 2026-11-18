# 跨项目的 agent 状态

状态：设计定稿（2026-11-18）。第一期（项目轨角标）已实现（2026-11-18），和 [project-rail-icons.md](project-rail-icons.md) 一起做；第二期（全部项目的会话列表）排在 [terminal-persistence.md](terminal-persistence.md) 之后。

## 要解决什么

同时在几个项目里开着 Claude Code / Codex 时，最常问的两句话：**哪个停下来在等我点允许？哪个改完了等我去验收？** 现在要一个个切过去看。

已有的地基：

- `ProjectBoard` 在后台读所有项目和工作树的改动数，并从钩子事件判断 `aiRunning`（菜单栏和 ⌘⇧O 在用）。
- `AgentSession`（AI 标签里的 ACP 会话）知道自己在跑、出错、还是在等权限（`needsPermission`），但只在当前打开的项目里。
- 钩子事件只有 `start / edit / stop` 三种（`AIEvent.Kind`），不知道 agent 在等人。

## 状态（按优先级，一个项目只显示最高的那个）

| 状态 | 颜色 | 什么时候算 |
| --- | --- | --- |
| 等你处理 | 橙 | 钩子最后一条事件是 `waiting`（见下）；或这个项目有 ACP 会话在等权限 |
| 出错了 | 红 | 这个项目有 ACP 会话出错退出（`State.failed`），且你还没看过那个会话 |
| 改完待验收 | 蓝 | 最后一条钩子事件是 `stop`、在 24 小时内，且项目里还有没验收的改动（工作区里的改动，不算暂存区） |
| 正在改 | 灰色细环 | 现在 `aiRunning` 的判断（最后一条不是 `stop`，30 分钟内） |
| 无 | 不画 | |

「改完待验收」用工作区改动数，不用总改动数：在 Folmi 里收下（暂存）了就不再提醒。`ProjectBoard.read` 解析 porcelain v2 时已经逐条看了，顺手按 XY 的 Y 列（或 `?`）多数一个 `unaccepted`。

## 新增「等你处理」的钩子事件

- Claude Code 的 `Notification` 钩子在它等权限或等输入时触发。`AIActivity.install` 里加一条：`add("Notification", matcher: nil, "notify")`。
- `folmi-hook notify`：往事件文件追加一条 `kind: waiting`（`AIEvent.Kind` 加一个 case），带上 `message` 字段里的文字（截断到 200 字）。
- `waiting` **不是改动**：不开批次、不进轮次、不影响整批撤回和按轮次看。读事件的地方（轮次、撤回、`TurnCallCheck` 等）要逐个确认会忽略它。旧版 Folmi 读到不认识的 kind 会解码失败：确认现有解码是逐行容错的，不会因为一行坏掉整个文件。
- 之后任何一条 `start / edit / stop` 都让它失效（只看最后一条事件）。
- Codex：如果当前 Codex 版本的钩子有对应的等待 / 请求权限事件就同样接上；没有就不接，Codex 的「等你处理」暂时只来自 ACP 会话。
- 已经装过钩子的项目没有这条：`AIActivity.status` 把「缺 Notification 钩子」算成可更新，「接入 agent」里显示「更新钩子」，不弹窗打扰。

## 第一期：项目轨角标

- 在项目方块右上角画一个 7 pt 圆点，外面一圈 1.5 pt 项目轨底色描边（和图标分开）。「正在改」画成细环，不转圈、不呼吸（省电，也不分散注意力）。
- 当前打开的项目也画。工作树行同样画（它们有自己的钩子事件）。
- 项目自己没事、但它的某个工作树有事时，项目方块也画那个工作树的最高状态。
- 悬停提示写清楚：「Claude 在等你处理：想运行 npm test」「Codex 改完了 · 5 个文件没验收」「Claude 正在改」。无障碍标签同样的文字。
- 展开项目轨时，名字下面加一行小字（只在有状态时）。

### 数据怎么来、多久更新

- **钩子事件：监听文件，不轮询。** 对每个项目（和工作树）的事件文件用 `DispatchSource.makeFileSystemObjectSource(.write | .extend)` 监听；有写入就只读文件尾 4 KB 更新那一行。文件还不存在时监听 `.git/folmi` 目录（或等下一次 board 刷新再挂）。
- **改动数：** 沿用 `ProjectBoard` 现在的刷新时机（启动、取回后、打开菜单栏 / ⌘⇧O），另外在收到 `stop` 事件时只刷新那一个项目。不加新的定时器。
- **ACP 会话：** 当前项目的 `AgentSession` 直接上报。切走项目后会话还在内存里的，照样上报。
- 状态合并放进 `ProjectBoard.Row`（加 `attention: AgentAttention?` 和提示文字），菜单栏和 ⌘⇧O 也用同一份，不再各算各的。

### 通知

- 「等你处理」来自钩子、且 Folmi 在后台时，发一条系统通知（沿用 `AINotifications` 的写法），同一个会话 5 分钟内只发一次。Claude Code 自己也可能通知，不重复也没关系，后面看实际情况再调。

## 第二期：全部项目的会话列表（终端持久化之后）

- AI 标签的「会话」列表加「当前项目 / 全部项目」切换，记住选择。
- 「全部项目」列出：各项目的 ACP 会话；后台终端里正在跑的 `claude` / `codex`（由 `folmi-pty` 报告每个终端的前台进程名）；钩子事件里最近 24 小时活跃的会话。
- 按状态优先级排序。选中按 ⏎：切到那个项目（或工作树），在跑的直接聚焦那个终端或 AI 标签；已经结束的给「接着聊」（ACP 的 resume / `claude --resume`）。
- 不做常驻的新面板。

## 不做

- 不接 OSC 7501。这是 Mayoi / herdr 自己的协议，Claude Code 和 Codex 本身不发，接了也拿不到数据。等你处理的信号来自钩子和 ACP。
- 不在 Dock 图标上显示角标（direction.md 已定）。

## 测试

- `folmi-hook notify` 写出 `waiting` 事件；之后的 `prompt` 让它失效。
- 轮次、整批撤回在事件里夹着 `waiting` 时结果不变。
- 状态优先级：同时有 waiting 和 stop+改动时显示等你处理；工作树的状态冒泡到项目。
- 已装旧钩子的项目，`AIActivity.status` 报可更新。
- 角标的悬停文字（在 FolmiTests 里读回）。

## 实现说明

- 本机 Codex 0.163.0 支持 `PermissionRequest`，已接入 `notify`。消息优先取钩子的 `message`，也接受 Codex 的 `tool_input.description`，再用工具名兜底。Claude 的安装配置接收 `Notification`，助手按通知类型记录需要人处理的事件。
- Claude Code 一轮结束后的 `idle_prompt` 会被忽略。钩子记录的 `waiting` 满 30 分钟后失效。
- 在 Claude Code 里批准 WebFetch、MCP 等非编辑工具后，`PostToolUse` 只匹配编辑工具和 Bash，橙色角标会保留到下一次编辑、轮次结束或等待事件过期。扩大匹配范围会让每次工具调用都额外启动一个进程，因此保留现有范围。
- 等待消息最多保留 200 个完整字符。对于组合表情等占用较多字节的消息，进一步截短，让该条记录能从 4 KiB 的日志尾部读到。
- 事件日志尚未创建时，先监听能打开的 `.git/folmi` 或 Git 管理目录。保留总览原有的 Git 状态刷新节奏，事件日志只在挂载监听、收到文件事件或日志被替换时读尾部。
- 已打开的项目按主窗口快照数工作区文件。后台沿用总览的 Git 状态读取，未跟踪目录可能由 Git 合并成一条记录。点钩子等待通知会打开对应项目或工作树。
- ACP 会话沿用现有生命周期，在内存期间按会话所属项目上报。已查看的错误会清除角标。
- 展开后的状态行保持单行。空间不足时截断，完整文案可通过悬停提示和无障碍标签读取。
