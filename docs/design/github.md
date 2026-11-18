# GitHub：推送并建 PR，评审意见交给 agent

状态：设计定稿，第一期待实现（2026-11-18）。

## 要解决什么

Folmi 的交付现在有「推送分支」「提交 Gerrit 评审」「运行自定义脚本」（`DeliveryKind`）。用 GitHub 的人推完还要去网页建 PR；同事的评审意见、失败的检查也要去网页看，再手动抄给 agent。

## 原则

- **认证全交给本机的 `gh`**。Folmi 不存 token，不做 OAuth。
- **只在用户操作时调用 `gh`**：打开 PR 面板、点刷新、自己点的推送和建 PR 之后。**不在后台定时查，也不跟着后台取回一起查**（AGENTS.md 的远端访问约定）。
- 不替用户合并、关闭 PR，不替用户发评论。
- 不在仓库里写任何文件；PR 信息不存进项目设置，每次从 `gh` 读。

## 找到 gh

- 依次找 `/opt/homebrew/bin/gh`、`/usr/local/bin/gh`，再用登录 shell 的 `PATH` 找一次（`/bin/zsh -lc 'command -v gh'`，结果在内存里缓存到下次启动）。
- 判断远端是不是 GitHub：当前分支上游所在远端（没有上游就用 `origin`）的地址，主机是 `github.com`，或 `gh auth status --hostname <主机>` 成功（GitHub Enterprise）。
- 没装或没登录时，相关按钮**置灰并写明原因**（AGENTS.md：能事先判断的事先判断），旁边给可复制的命令：`brew install gh`、`gh auth login`。

## 第一期

### 1. 推送并创建 PR

在交付面板（`DeliverySheet`），推送类的方案、远端是 GitHub 时：

- 当前分支没有打开的 PR、且不是默认分支：主按钮旁多一个「推送并创建 PR」。
- 已经有打开的 PR：推送按钮写成「推送（更新 PR #123）」，下面一行小字显示 PR 标题和状态。
- 点「推送并创建 PR」先照常推送（走现有的推送流程和检查），成功后展开 PR 表单：
  - 标题：分支上只有一个新提交时用它的第一行；多个时用 Folmi 预生成的提交说明的思路，概括成一行（没有 AI 设置就用分支名）。
  - 描述：新提交的列表 + 改动的文件数。用户可改。
  - 目标分支：仓库默认分支（`gh repo view --json defaultBranchRef`），可改。
  - 「草稿」勾选框。
  - 按钮「创建 PR」→ `gh pr create --head <分支> --base <目标> --title <标题> --body-file - [--draft]`。
- 推送成功但建 PR 失败：推送不回滚，表单保留内容，显示 `gh` 的错误，可以重试。
- 建好后在面板里显示链接「在浏览器打开 PR #124」。

### 2. PR 状态胶囊

- 当前分支有打开的 PR 时，改动栏顶部（和现在 Gerrit「评审中」的位置一致，参考 `ReviewWatch`）显示一个胶囊：`PR #42 · 2 项检查失败 · 3 条评论没解决`，加「x 分钟前」。
- 数据来自 `gh pr view <分支> --json number,title,url,state,isDraft,reviewDecision,statusCheckRollup,headRefOid`，加上 GraphQL 查没解决的评审讨论（`gh api graphql`，`reviewThreads(isResolved: false)`，取 `path`、`line`、`originalLine`、作者、正文）。
- 什么时候查：打开项目后第一次显示改动栏时查一次；用户推送或建 PR 后查一次；点胶囊的刷新按钮。其他时候显示上次的结果和时间。
- 结果只放内存。

### 3. 评审意见、失败的检查交给 agent

点胶囊打开 PR 面板（弹出层，不常驻）：

- **没解决的评审意见**，按文件分组。每条：
  - 「跳到位置」：本地 `HEAD` 等于 PR 的 `headRefOid` 时直接跳到那一行；不等时也跳，但标「本地代码可能已经变了」。
  - 「加到 AI 输入框」：和本地审查评论一样（`ReviewComments` 现在「加到当前 AI 会话的输入框」那条路），带文件和行号、评论人和原文，**不自动发送**。
  - 多选后一次加进去。
- **失败的检查**：列出名字和链接。GitHub Actions 的检查可以「加到 AI 输入框」：用 `gh run view <run id> --log-failed` 取失败步骤的日志，只保留最后 200 行，作为附件放进去。
- agent 改完照常在 Folmi 里一处一处验收、提交、推送，推送按钮显示「推送（更新 PR #42）」。

## 第二期（暂不做，先记下）

- Issue 列表：选一条「交给 agent」或「在新工作树处理」，标题、正文、评论放进输入框。
- 在 Folmi 里审别人的 PR：取回 PR 引用后用差异画布看，写评论，作为 GitHub 评审提交。
- 合并 PR、回复评论。

## 实现要点

- `DeliveryKind` 不加新 case：GitHub 是推送方案的附加能力，按远端判断。
- `gh` 调用都走 `CommandRunner.run`（带超时，`GH_PROMPT_DISABLED=1`、`GH_NO_UPDATE_NOTIFIER=1`、`NO_COLOR=1`），JSON 解析放进可测的纯函数。
- 文件放 `Sources/Folmi/GitHub*.swift`；解析 `gh` 输出的部分不依赖界面，可以放 `FolmiCore`。

## 测试

- 用临时目录里的假 `gh`（shell 脚本按参数返回固定 JSON）测：识别 GitHub 远端、没装 / 没登录时按钮置灰的原因、建 PR 的命令参数、状态胶囊文字、评审意见解析、日志截断。
- 不访问真实网络。
