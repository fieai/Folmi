# AI 路线

日期：2026年10月18日  
状态：四步主体已实施；真实 Codex 和 Claude 的对话、文件修改、MCP 评论反馈均已验收，Codex 批次撤回与恢复也已验收。

当前对外名称统一为 Folmi，helper 使用 `folmi-hook`，MCP 注册名为 `folmi`，打开工具为 `show_in_folmi`，生成链接为 `folmi://`。下文方案按当前名称维护；末尾实施记录与链接的验收记录保留 2026-10-18 当时的命令、路径和结果，不代表本轮改名后的验证结论。仓库本地审阅数据放在 `<gitdir>/folmi/`。

## 定位

工作台负责**看 AI 改了什么、决定收下哪些**，写代码交给 Claude Code / Codex。AI 功能只做两类事：

- **把验收做快**：提交说明、说人话、解释改动、风险排序。用户自己配的 LLM 就够用。
- **把验收结果还给 agent**：评论、拒绝了什么、长期规则。走 MCP 和 hooks，不在 App 里再做一个 agent。

**对话框里聊的就是 agent 本身**：Claude Code 或 Codex 的会话，不是另起一个只能回答问题、不能改代码的模型。这是对 [direction.md](../direction.md) 原则 4「不重造 Claude Code」的延伸，不是推翻它。

## 顺序

| 步 | 内容 | 解决什么 | 规模 |
| --- | --- | --- | --- |
| 1 | 按用途选模型 + 服务商预设 + 借用本机 CLI | 便宜的活用便宜的模型，没 key 也能用 | 小 |
| 2 | MCP server：agent 能读审阅评论、看验收结果 | 闭环：评论不用再粘贴到终端 | 中 |
| 3 | 从拒绝和评论里提议长期规则 + 「记住了什么」页 | 越用越顺手，agent 也越改越对 | 中 |
| 4 | ACP：终端卡片的 AI 标签变成 agent 会话 | 对话框 | 大 |

前一步不依赖后一步。第 2 步要先把评论写进仓库目录（见下文），第 3 步要先有决定记录，这两件都在各自的步骤里做。

---

## 第 1 步：自定义 LLM 配置

### 现状

`AIService.swift`：`AISettings` 只有一组 `baseURL / model / format`，钥匙串只存一个 key（account `api-key`），没配置时退回 `claude -p`（`useClaudeCLI`）。所有用途共用这一组配置。

### 要做

1. **服务商**：一项配置 = 名字 + 类型 + 地址 + 模型。类型有四种：
   - `openai`：OpenAI 兼容接口，覆盖 OpenAI、DeepSeek、OpenRouter、Ollama、LM Studio
   - `anthropic`
   - `claudeCLI`：`claude -p`
   - `codexCLI`：`codex exec`，只读沙箱，不允许它改文件
   
   内置预设：Anthropic、OpenAI、DeepSeek、OpenRouter、Ollama（`http://localhost:11434/v1`，不要 key）、LM Studio。选预设只需要填 key 和模型。
2. **按用途选服务商**，用途固定四个：
   - 提交说明（后台预生成，高频）
   - 说人话 / 去 AI 腔
   - 解释改动 / 问 AI
   - 规则总结（第 3 步用）
   
   默认全部用第一个可用的服务商。设置页是「用途 → 服务商」四行下拉框，不展开温度之类的参数。
3. **每个服务商一个 key**：钥匙串 account 用 `api-key.<服务商 id>`。启动时把旧的 `api-key` 迁移到第一个服务商名下，迁移后删掉旧条目。
4. **本机专用开关**：服务商可以标记「只在本机」（Ollama、LM Studio 默认打开）。项目可以设成「只用本机服务商」，打开后远程服务商在这个项目里不可选。`SecretScan` 照旧在发送前检查。
5. **测试按钮**：发一条很短的请求，显示用时和返回的第一行。失败时原样显示错误，不吞掉。

### 涉及文件

`AIService.swift`（`AISettings` → 服务商列表 + 用途映射、`AIClient.current(for:)`、`AIKeychain` 按 id 读写、`CodexCLI`）、`ReviewViews.swift`（`AISettingsSheet`）、`ReviewFlow.swift` / `AIAssist.swift`（调用处传入用途）。`importEnv` 改成导入为一个服务商。

### 验收

- 旧配置升级后行为不变：原来能生成提交说明的，升级后照样能。
- 提交说明配 DeepSeek、解释改动配 Claude，两边各自生效（看设置页旁边显示的「来源」）。
- 只装了 `codex`、没有 key 也没有 `claude` 时，四个用途都能用。
- 打开「只用本机」的项目里，远程服务商不可选，已选的会提示改选。
- 测试：设置的编解码和迁移、按用途路由、钥匙串按 id 读写（用测试专用的 service 名）。

---

## 第 2 步：MCP server

### 为什么先做它

用户在 Claude 桌面 app、Codex app、终端里的 Claude Code 里都可能在工作。桌面 app 不能被别人当子进程驱动，但都能接 MCP server。所以想让这些 app 和工作台互通，MCP 是唯一一条路，而且一次接入所有 app 都能用。

### 边界

agent 可以**读**验收状态，可以**标记**自己处理过的评论，可以**请工作台打开**某处给用户看。agent **不能**收下、丢弃、提交、推送：验收是用户的事（原则 1）。

### 工具

| 工具 | 作用 |
| --- | --- |
| `list_review_comments` | 当前仓库的审阅评论：文件、行号、锚定的代码、评论内容、是否已过时 |
| `mark_comment_addressed(id, note)` | 标成「AI 说已处理」并附一句说明。工作台显示这个标记，由用户确认后删除评论 |
| `review_status` | 还有几处没看、几处已暂存、最近一轮 AI 批次改了哪些文件 |
| `recent_decisions(limit)` | 最近收下 / 拒绝了哪些改动（第 3 步的决定记录，没有时返回空） |
| `show_in_folmi(path, line)` | 在 Folmi 打开这个文件的改动并定位到这一行 |

### 实现

- **进程**：`folmi-hook mcp`，即现有 helper 的 MCP 子命令，走 stdio JSON-RPC。不新增 target，由 `build-app.sh` 打包这个 helper。
- **数据**：评论现在存在 App 偏好里（`FolmiModel+Persistence.swift` 的 `reviewComments`）。改成同时写一份到 `<gitdir>/folmi/comments.json`，App 写、MCP 读。`mark_comment_addressed` 写到 `<gitdir>/folmi/comment-replies.jsonl`，App 刷新时读进来。目录和 hooks 的 `events.jsonl` 是同一个，不另开目录。
- **打开**：`show_in_folmi` 调 URL scheme `folmi://open?repo=…&path=…&line=…`。App 注册这个 scheme；没运行时由系统启动它。旧工具名和旧链接仅作为迁移兼容入口。
- **接入**：设置里加一个「接入 agent」页，每个客户端一行，显示配置片段，点「写入」前先给用户看会改哪个文件：
  - Claude Code：项目的 `.mcp.json`（或提示运行 `claude mcp add`）
  - Claude 桌面 app：`~/Library/Application Support/Claude/claude_desktop_config.json`
  - Codex：`~/.codex/config.toml` 的 `[mcp_servers.folmi]`
- **Codex 的 hooks**：顺带调研 Codex 现在的钩子 / notify 机制。能接就复用 `folmi-hook prompt|pre|post|stop`，让活动胶囊和整批撤回对 Codex 也生效。接不了就记录原因，不硬做。

### 涉及文件

`Sources/FolmiHook/main.swift`（`mcp` 子命令）、Core 新增 `MCPServer.swift`（JSON-RPC 编解码和工具分发，放 Core 方便测试）、`FolmiModel+ReviewComments.swift`（写 / 读仓库目录里的评论和回复）、`ReviewComments.swift`（「AI 说已处理」状态）、`FolmiApp.swift`（URL scheme）、`AIActivityViews.swift` 旁边的接入设置页。

### 验收

- 在终端的 Claude Code 里说「看一下工作台里的评论并修掉」，它能列出评论、改完调用 `mark_comment_addressed`。工作台里的评论显示「AI 说已处理」，不需要粘贴。
- Claude 桌面 app 接入后能调用 `review_status`。
- `show_in_folmi` 在 App 没运行时能拉起 App 并定位到那一行。
- agent 侧拿不到任何能改 Git 状态的工具。
- 测试：MCP 请求 / 响应的往返（stdin/stdout 管道）、评论文件读写、回复合并、URL 解析。

---

## 第 3 步：越用越顺手

### 原则

进化的是**数据和规则**，不是 App 的代码。每一条变化都在「记住了什么」页里看得见、改得了、删得掉，写进项目文件之前必须经过用户同意。

### 要做

1. **决定记录**：收下 / 丢弃每一处时追加一行到 `<gitdir>/folmi/decisions.jsonl`：时间、路径、动作、改动的简短特征（加了几行、减了几行、是不是只改注释或格式）、所属 AI 批次。只记特征和前几行文本，不记整个文件。在 `ReviewFlow.swift` 的 `acceptHunk / rejectHunk / acceptFile / rejectFile` 里写。
2. **找模式**：先用规则，不用 LLM。
   - 同一路径或同一模式（如 `*.lock`、`package-lock.json`）被丢弃 ≥3 次
   - 只改注释的改动被丢弃 ≥3 次
   - 同类评论出现 ≥2 次：比较评论文本的关键词重合
   
   命中后再调用「规则总结」用途的模型，把它写成一句给 agent 的要求，比如「不要修改 package-lock.json，除非任务明确要求」。
3. **提议**：在收工空状态（`DoneState`）里显示一张小卡片：「最近 3 次都丢弃了 lockfile 的改动，要不要让 Claude 以后别动它？」，按钮是「写进规则」和「不用」。点「不用」后同一模式 30 天内不再提。
4. **写到哪**：写进项目根目录的 `CLAUDE.md`，有 `AGENTS.md` 时两边都写（Codex 读 `AGENTS.md`）。放在一个有标记的段落里：
   
   ```markdown
   <!-- folmi:rules -->
   - 不要修改 package-lock.json，除非任务明确要求。
   <!-- /folmi:rules -->
   ```
   
   只改这个段落里面的内容，不碰文件的其他部分。写之前显示 diff，写完会作为一处普通改动出现在改动列表里，用户自己决定提不提交。
5. **提交说明学仓库风格**：生成时带上这个仓库最近 20 条提交标题作为示例（语言、前缀、长度跟着仓库走），不再只靠全局提示词。
6. **「记住了什么」页**：一个页面列出全部记忆：已写入的规则、被拒的提议（可以撤销「不用」）、⌘K 常用、每日统计。每条都能删。

### 涉及文件

`ReviewFlow.swift`（写决定）、新增 `Learning.swift`（模式规则、提议冷却、规则段落读写）、`ReviewViews.swift`（`DoneState` 提议卡、「记住了什么」页）、`AIService.swift`（`AIPrompts` 加规则总结和提交风格示例）。

### 验收

- 在演示仓库里连续 3 次丢弃 lockfile 改动后，收工时出现提议；点「写进规则」后 `CLAUDE.md` 多出带标记的一段，并出现在改动列表里。
- 文件里已有的内容一字不变；再次写入只更新标记段落。
- 「不用」之后同一模式不再出现，在「记住了什么」里撤销后恢复。
- 中文提交历史的仓库生成中文说明，`feat:` 风格的仓库生成同样风格。
- 测试：模式检测（各条阈值）、标记段落的插入 / 更新 / 文件不存在、冷却期、`decisions.jsonl` 读写。

---

## 第 4 步：对话框 = agent 会话（ACP）

### 位置和出现方式

- **不常驻侧栏。** 长对话在**终端卡片的 AI 标签**里（现在 `EditorCardViews.swift` 里那个 `PaneTab(title: "AI")`）。右下角就是和 agent 说话的地方，终端和 AI 标签是同一种心智。
- **就地提问照旧**：选中 diff / 代码 / 评论按 ⌘L，在旁边弹卡片。说人话、解释这类一次性的问题用第 1 步配的模型，答完就收起。卡片上的「交给 agent」把问题和选区带进 AI 标签的会话。
- **⌘K 兜底**：没有匹配的命令时，最后一行是「问 agent：…」。

### 为什么是 ACP

ACP（Agent Client Protocol）是编辑器驱动 agent 的通用协议，stdio JSON-RPC。Claude Code 和 Codex 都有 ACP 适配器，接一次两边都能用。agent 的文件修改和权限请求都是协议里的结构化消息，正好映射到工作台已有的东西：

| ACP 里的东西 | 工作台怎么显示 |
| --- | --- |
| agent 的回复、计划 | AI 标签里的消息流 |
| 工具调用 / 文件修改 | 一行摘要 + 「看改动」，改动照常进入改动列表和 AI 批次 |
| 权限请求 | 卡片上的「允许一次 / 总是允许 / 拒绝」，危险命令沿用 guardrails 的判断 |
| 上下文（选区、评论、文件） | ⌘L、评论「交给 agent」时作为附件送进去 |

### 实现要点

- Core 新增 `ACPClient.swift`：启动适配器进程，处理 JSON-RPC 的会话、流式消息、权限回调。会话记录存在 `<gitdir>/folmi/sessions/`。
- AI 标签顶部选择 agent：Claude Code / Codex，只列出本机能找到的。
- 和终端的关系：两边可以同时开。AI 标签里的会话同样会触发 hooks，所以胶囊、整批撤回、回放不区分改动来自哪边。
- 现在的 `AIAssistCard(docked: true)` 退回成就地卡片专用，AI 标签换成会话视图。

### 实施前要定的事

1. **适配器怎么装**：Claude Code 和 Codex 的 ACP 适配器目前大多是 npm 包，需要 Node。可选做法：检测到就用；检测不到时提示一条安装命令；或者不走适配器，改接各家自己的协议（`claude --input-format stream-json --output-format stream-json`、`codex app-server`），要写两份但不依赖 Node。到这一步时先调研两边适配器的成熟度再选。
2. **登录和计费**：会话用用户本机 CLI 的登录，App 不碰账号和 key。
3. **会话恢复**：重启 App 后是继续上次的会话，还是只保留记录、新开会话。

### 验收（草案，实施前细化）

- 在 AI 标签里让 Claude 改一个文件，改动出现在改动列表里，胶囊显示这一轮，可以整批撤回。
- 切到 Codex 做同样的事，表现一致。
- 权限请求在卡片上完成，拒绝后 agent 收到拒绝并继续。
- 终端和 AI 标签同时有会话时互不干扰。

---

## 不做

| 项 | 理由 |
| --- | --- |
| App 自带的写代码 agent | 原则 4。写代码是 Claude Code / Codex 的事 |
| 常驻的聊天侧栏 | 和终端抢入口；需要长对话时用 AI 标签 |
| 给 agent 收下 / 提交 / 推送的权限 | 验收是用户的决定 |
| 静默学习、自动改规则 | 每条规则都要用户同意，并且看得见、删得掉 |
| App 修改自己的代码或提示词 | 进化只发生在数据和项目规则里 |

---

## 实施记录（2026-10-18）

- **第 1 步**：设置文件改成 `providers` + `routes`，旧的单接口文件读进来变成一个叫「已导入」的服务商，旧 Key 搬到 `api-key.imported`。命令行不存进列表，装了就出现（`cli.claude` / `cli.codex`）。用途选了某个服务商但它跑不了时直接报出来，不偷偷换成别的。codex 用 `codex exec --skip-git-repo-check --ephemeral --sandbox read-only --output-last-message`，只读、不留会话文件。两个命令行常是 Node 脚本，运行时把它们所在的目录放进 PATH（nvm 装的也能找到）。
- **第 2 步**：MCP 走 `folmi-hook mcp`（stdio，一行一条 JSON-RPC）。App 把评论、审阅状态写进 `.git/folmi/comments.json`、`review-status.json`（内容没变不写，文件监听忽略这几个 App 自己写的文件），agent 的回复追加到 `comment-replies.jsonl`。不在仓库里启动的客户端（Claude 桌面 App）用 App 记在 `app.json` 里的当前项目。Claude Code 用 `claude mcp add --scope user` 接入，没装 claude 命令行时给出命令让你自己跑，不直接改 `~/.claude.json`（Claude Code 自己会重写这个文件）。
- **Codex 钩子已补齐并实测**：初版没有接入。当前使用项目 `.codex/hooks.json`，通过 Codex 原生 `/hooks` 审核信任；helper 支持 apply_patch 一次多文件、移动、Stop/Interrupt，保留独立缺失标记的 V2 快照。真实 Codex 已验证活动胶囊、整批撤回和恢复。标题生成的空批次不再覆盖文件批次。见 本轮验收记录。
- **第 3 步**：决定记在 `.git/folmi/decisions.jsonl`（只存路径、加减行数、前 4 行和是否只改注释），评论另记 `note-log.jsonl`，提议状态在 `learning.json`。三条规则：同一文件或锁文件 30 天内丢弃 ≥3 次且多于收下次数；只改注释的改动丢弃 ≥3 次；两条评论字符二元组重合 ≥0.5。评论那一类在写入弹窗里用「总结规则」的模型改写成一句（可改）。写过的提议即使规则后来被删也不再提。提交说明：仓库最近 20 条标题一半以上是 `type: ` 格式才用 Conventional Commits，否则不加前缀、跟着仓库写。
- **第 4 步，实施前要定的三件事的决定**：
  1. 适配器：官方 ACP 注册表里的 `@agentclientprotocol/claude-agent-acp` 和 `@agentclientprotocol/codex-acp`（两个都在 2026-10-16 更新过），默认用 `npx -y` 启动，需要 Node；命令在 AI 设置里可改（比如换成装好的二进制）。
  2. 登录和计费：用你本机 claude / codex 的登录，App 不碰账号。没登录时提示去终端登录。
  3. 会话恢复：重启后显示上次的对话记录（只读），下一条消息开新会话；没有用 ACP 的 `session/load`。
- 第 4 步其他：不向 agent 提供文件读写和终端能力（它自己改工作区，改动列表照常显示）；每个会话都带上工作台的 MCP server。真实 Codex 适配器 2.2.2 已在 App 里完成对话、apply_patch 修改文件、读取审阅评论和 mark_comment_addressed；Claude 后续也已完成真实对话、Edit 修改、MCP 评论读取与反馈，详见 Claude 验收记录。
