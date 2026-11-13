# 验收：改动很多时，「改动」列表不再卡住

2026-11-12。执行：Codex。验收：Claude Code 按本文逐条检查，结果由用户决定是否提交。

## 背景

2026-11-11 切换到有约 5,000 个改动文件的项目时，Folmi 两次卡死后被强制退出。卡死报告里主线程一直停在 SwiftUI 的
`OutlineListCoordinator.recursivelyDiffRows` → `ForEach`：「改动」列表把每个文件都当成一行交给 `List`，行数没有上限。

当天的修复（`Sources/Folmi/ChangesCard.swift`，尚未提交，**保留，不要回退**）让每一行变便宜了，但耗时仍然随文件数增长，
而且没有任何测试或性能门槛守着。

这次要做到：**列表交给 SwiftUI 的行数有上限，切换项目的耗时和改动文件的总数脱钩，并且有测试和性能门槛防止再犯。**

## 要做的事

### 一、文件多时，按文件夹展示并默认收起

「一组」指「改动」面板里的暂存区或工作区，各自单独判断；「这一组要显示的文件」是搜索过滤之后的结果。

1. 一组要显示的文件 **超过 500 个** 时（阈值写成一个有名字的常量，测试引用它，不要在多处写 500）：
   - 这一组按文件夹展示，不管用户选的是平铺还是按文件夹；
   - 文件夹默认全部收起，只显示顶层文件夹和直接放在仓库根目录的文件；
   - 每个收起的文件夹行上显示里面有多少个文件（含子文件夹里的），例如 `Sources　1,204`。
2. 用户可以点开任何文件夹，点开后只多出它的直接内容（子文件夹仍然收起）。点开、收起的状态在快照刷新后保留；切换项目后清空（和现在一样）。
3. 不超过 500 个时，行为和现在**完全一样**：平铺就是平铺，按文件夹展示时默认全部展开。
4. 任意一组因为超过阈值被强制按文件夹展示时，工具栏上的「切换为平铺展示 / 切换为按文件夹展示」按钮置灰，
   提示写明原因：`改动超过 500 个，只能按文件夹展示。`（数字取自常量。）用户原来选的展示方式不改，文件数降回阈值以下就恢复。
5. 被选中的文件必须看得见：选中的文件变了（点「下一处」、从别的面板跳过来、刚切到这个项目时恢复的选中等，不限于在列表里点击），
   它所在的各级文件夹自动展开，并滚动到这一行。用户之后手动收起这个文件夹是允许的，不要马上又弹开。
6. 搜索：过滤后的结果超过 500 个同样默认收起；不超过就和现在一样全部展开。
7. 分组标题上的数量、「全选」「全部暂存」「全部取消」仍然针对这一组的全部文件，不受收起影响。
8. 每组里行的计算（`ChangeListRow.rows`）不能在每次界面刷新时对全部文件重做：同一份文件列表、同样的展开状态只算一次。
   放在哪里由你决定，以第三节的门槛为准。

### 二、回归测试

加在 `Tests/FolmiTests/ChangeListTests.swift`（照 `testSwitchingAndFoldingTheRenderedChangesList` 的写法，真的把面板放进窗口）。
**不要修改现有测试里的断言**；如果某条现有断言必须改，停下来在最后的报告里说明原因，不要自己改掉。

大仓库的造法：`DemoRepository.create()` 之后在工作区写 5,000 个未跟踪的小文件，分在 50 个顶层文件夹里，每个 100 个
（其中一个文件夹再分两层子文件夹）。这一段写成测试里的辅助函数，供下面各条共用。

- **T1 行数有上限**：载入快照后，面板里 `NSTableView.numberOfRows` 不超过 80（50 个文件夹 + 演示仓库自带的改动 + 分组标题等）。
- **T2 不卡主线程**：从给 `model.snapshot` 赋值到列表画完，主线程单次阻塞不超过 **250 ms**（debug 构建）。
  量法：赋值前在主线程起一个每 10 ms 记一次时间的心跳（`Timer` 或 `Task` 均可），取最大间隔；同时断言整个过程在 1 秒内完成。
- **T3 能点开**：点一个文件夹行，行数恰好增加 100；用 `ScreenText.read` 读回屏幕，能看到里面的一个文件名。再点一次，行数恢复。
- **T4 点开一个大文件夹也不卡**：另造一个直接放了 2,000 个文件的文件夹，点开它，主线程单次阻塞不超过 1 秒。
- **T5 文件夹上的数量**：屏幕上读得到收起的文件夹行上的文件数（含子文件夹的那个要等于两层之和）。
- **T6 选中的文件看得见**：`model.selectFiles([某个深层文件], in: .working)` 之后，这个文件所在的行在表格里，并且是选中状态；
  其他顶层文件夹仍然收起。
- **T7 按钮置灰**：超过阈值时切换展示方式的按钮是 disabled，提示文字是上面第 4 条那一句；把文件删到 500 个以内并刷新快照后，
  按钮恢复，展示方式回到用户原来选的（测试里先设成平铺，验证回到平铺）。
- **T8 阈值边界**（不需要窗口的单元测试）：恰好 500 个文件时结果和现在的 `ChangeListRow.rows` 一致；501 个时默认收起。
- **T9 搜索**：搜索一个只匹配 3 个文件的词，三个文件都直接可见（它们所在的文件夹是展开的）；清空搜索后回到默认收起。

### 三、性能门槛

`scripts/perf.sh` 现在只造 8 个文件左右的改动。加一个「切换到大项目」的场景：

- 脚本在临时目录里再准备一个仓库，工作区有 5,000 个未跟踪文件（50 个文件夹 × 100），和原来的小仓库一起写进测量用的 workspace 文件。
- `--perf-run` 在两个项目之间来回切换 3 次，每次记录一条 `switch.largeProject`：从发起切换，到大项目的「改动」列表那一帧提交完成
  （用 `PerfLog` 现有的「帧提交之后」的写法）。同时记录 `switch.largeProject.stall`：这次切换期间主线程最长的一次阻塞。
- `scripts/perf-budget.tsv` 加两行。上限按实测中位数加约 30% 余量取，但**不得高于**：
  - `switch.largeProject`　1000 ms
  - `switch.largeProject.stall`　150 ms
- 实测超过这两个硬上限，说明第一节没做到位：继续改实现，不要放宽上限。实在做不到，停下来在报告里写清楚卡在哪里和实测数字。
- 现有的 7 项门槛不能变差到超限，也不要改它们的上限。

### 四、文档

- `CHANGELOG.md` 的「## 未发布」里已经有一条修复说明，在「改进」下加一条，例如：
  `改动超过 500 个文件时，「改动」列表按文件夹展示并默认收起，打开和切换大项目不再变慢。`
- 改完运行 `python3 scripts/site-changelog.py`，不要手改 `site/index.html`。

## 不做的事

- **不改 Git 状态的取法**：`GitRepository.state()`、`--untracked-files=all`、指纹的计算都不动。
  「把未跟踪的文件夹合成一行」牵涉到收下、丢弃、暂放、没验收标记怎么对待一整个文件夹，这次不做。
- 不把列表换成 `NSTableView` / `NSOutlineView` 的 AppKit 实现。
- 不给列表加「只显示前 N 个」的截断。
- 不改文件树（「文件」那一页）、不改大仓库模式。
- 不提交、不推送、不发版、不部署官网；不改 `VERSION`。

## 约定（见 `AGENTS.md`）

- 界面文字用中文，写给不太会 Git 的人看；注释用英文，写「为什么」。
- App 和 Core 在 Swift 6 严格并发下编译；SwiftUI 大表达式拆成函数或局部 `let`。
- 像素主题的字体是裁剪过的，新增的界面文字里如果有生僻字，重新运行 `scripts/subset-pixel-font.py`。

## 怎样算完成

依次执行，全部通过才算完成：

```sh
swift build 2>&1 | grep -E "warning:|error:"          # 没有新增的警告和错误
./scripts/test.sh > /tmp/folmi-test.log 2>&1; echo $? # 退出码 0
grep -E "\.swift:[0-9]+: error:" /tmp/folmi-test.log  # 没有输出
./scripts/perf.sh --budget 3                          # 9 项全部 ✓
./scripts/build-app.sh                                # 打包成功
```

`test.sh` 要 2–3 分钟，会真的打开窗口；`perf.sh` 会把 App 窗口调到前面。输出里大量的 `CoreData: error` 是系统噪音。

## 最后的报告

用中文，写明：

1. 改了哪些文件，每个文件一句话。
2. T1–T9 各自对应的测试函数名。
3. `perf.sh --budget 3` 输出的 9 项门槛原文（实测值和上限）。
4. T2、T4 实测的主线程最长阻塞。
5. 没做到的、和本文不一致的、你拿不准的地方。没有就写「没有」。

---

# 第 2 轮返工（2026-11-12）

第 1 轮复核结果：`./scripts/test.sh` 退出码 0、没有失败行；功能部分（第一节 1–8、T1–T9）通过，现有断言没有被改。
下面三件事没过，按顺序处理。**第一、二节其余内容不要重做。**

## R1 去掉「选中文件时清空搜索」

第 1 轮加了一个验收说明里没有的行为：选中的文件被当前搜索词过滤掉时，把搜索框清空
（`FolmiModel.searchAtFileSelection`，`ChangesCard.swift` 里 `.task(id: revealKey)` 中的 `model.fileSearch = ""`）。
它对 500 个以内的小项目同样生效，违反第一节第 3 条「行为和现在完全一样」，而且会悄悄丢掉用户输入的搜索词。

- 删掉 `searchAtFileSelection` 和清空搜索的那一段；`selectedFileID`、`area` 恢复成原来的普通属性。
- 有搜索词时：选中的文件匹配搜索词，就照常展开它所在的文件夹并滚动过去；不匹配，就和改动前一样，什么也不做。
- `testSelectingDeepFileRevealsAndScrollsWithoutOpeningOtherFolders` 里依赖这个行为的部分（先搜 `NoMatchingFiles`、
  断言 `fileSearch == ""`）改掉：不带搜索词选中深层文件。另加一条断言：带一个不匹配的搜索词选中文件后，搜索词原样保留。

## R2 性能数字要在安静的机器上测，并且查清主线程那一下在做什么

第 1 轮的数字不能用来下结论。复核时这台机器的 1 分钟负载是 70–80（12 核，别的任务在跑 iOS 模拟器和 xcodebuild），
同样条件下没有改过的 0.15.0 更差，7 项旧门槛里有 5 项不过：

| | 上限 | 第 1 轮报告 | 复核（当前代码） | 复核（0.15.0 基线） |
|---|---|---|---|---|
| launch.firstContentFrame | 1100 | 1528.5 | 1588.0 | 2255.2 |
| launch.readerPainted | 1450 | 1904.2 | 1833.3 | 2341.0 |
| switch.largeProject | 240 | 267.4 | 201.0 | — |
| switch.largeProject.stall | 150 | 200.6 | 153.6 | — |

所以两项启动指标超限**不是这次改动造成的**，不要为它们改代码，也不要动它们的上限。
`switch.largeProject.stall` 九次采样在 106–262 ms 之间，在上限附近，带着这样的负载判断不了。要做的是：

1. **测之前先看负载。** `perf.sh` 带 `--budget` 时，开始前读 1 分钟负载（`sysctl -n vm.loadavg`）；高于核数（`sysctl -n hw.ncpu`）就每 30 秒再看一次，
   最多等 10 分钟；等不到就照常测，但在「性能门槛」那一段最前面打印一行 `⚠ 测量时机器负载 N（核数 M），数字仅供参考`，退出码照旧。
   不带 `--budget` 时只打印这一行，不等。
2. **查清那 100–250 ms 主线程在做什么。** 用 `sample` 或 Instruments 的 Time Profiler（`Performance.swift` 开头有录制命令）
   对着「切换到大项目」录一次，在报告里列出主线程上最重的 3 段调用和各自的大致耗时，并说明每一段**是否随改动文件数增长**。
   随文件数增长的那些要处理掉（挪到主线程之外，或者只对看得见的行做）；不随文件数增长的（比如切换项目本身固定要重建的界面）写明即可。
3. **`switch.largeProject` 的上限**：240 是按一次测量的中位数加 30% 定的，这次复核三轮里有一轮就到了 267。
   在负载正常时用 `./scripts/perf.sh --budget 5` 重新测，按那次的中位数加约 30% 重定这两行，仍不得高于硬上限（1000 / 150），并更新 tsv 里的注释。
4. 在负载正常的机器上 `switch.largeProject.stall` 的中位数如果落在 150–200 ms 之间，而 R3 通过、热点也已经确认不随文件数增长：
   **停下来如实报告，不要为了压到 150 以下去做别的改动，也不要放宽上限。** 150 这个数是定验收时估的，由验收方决定要不要调整。

## R3 加一项「不随文件数增长」的门槛

绝对毫秒数受机器状态影响，这次真正要保证的是耗时和文件总数脱钩。加一个相对的检查：

- `perf.sh` 再准备一个更大的仓库 `perf-huge`：20,000 个未跟踪文件，50 个顶层文件夹，每个文件夹下 4 个子文件夹，每个子文件夹 100 个文件
  （这样收起时的行数、以及选中第一个文件后展开出来的行数，都和 5,000 个文件的仓库差不多，差别只在文件总数）。
  为了可比，把 `perf-large` 也改成同样的两层结构：50 个顶层文件夹，每个下面 1 个子文件夹，100 个文件。
- `--perf-run` 对它做同样的三次往返，记录 `switch.hugeProject` 和 `switch.hugeProject.stall`。
- 带 `--budget` 时增加一条检查并计入通过与否：
  `switch.hugeProject.stall` 的中位数 ≤ `switch.largeProject.stall` 的中位数 × 1.5 + 30 ms。打印成和其他门槛一样的一行（✓ / ✗、两个实测值、算出来的上限）。
- `switch.hugeProject` 本身（总耗时）只打印，不设门槛：`git status` 和指纹计算在后台线程，文件多了变慢是正常的。
- 这一条不过，说明主线程上还有随文件数增长的工作，按 R2 第 2 步找出来处理。

## 这一轮怎样算完成

```sh
swift build 2>&1 | grep -E "warning:|error:"          # 没有新增的警告和错误
./scripts/test.sh > /tmp/folmi-test.log 2>&1; echo $? # 退出码 0
grep -E "\.swift:[0-9]+: error:" /tmp/folmi-test.log  # 没有输出
./scripts/perf.sh --budget 5                          # 见下
./scripts/build-app.sh                                # 打包成功
```

性能门槛这一步：负载正常（没有 ⚠ 那一行）时要全部 ✓。等了 10 分钟负载仍然高，就以 R3 的相对检查和 5 项 `switch.*` 旧门槛为准，
两项启动指标和两项大项目绝对值如实报告，不算你没完成。

## 这一轮的报告

1. R1：改了什么，对应的测试断言。
2. R2：测量时的负载；主线程最重的 3 段调用、各自耗时、是否随文件数增长、怎么处理的。
3. R3：`switch.largeProject.stall` 和 `switch.hugeProject.stall` 的中位数，以及那一行检查的原文。
4. `perf.sh --budget 5` 的「性能门槛」整段原文。
5. 没做到的、拿不准的地方。没有就写「没有」。

---

# 第 3 轮返工（2026-11-12）

第 2 轮复核（解锁、1 分钟负载 5–7）：`./scripts/test.sh` 退出码 0、没有失败行；T2 134 ms、T4 185 ms；
`switch.largeProject` 198.3 ms、`.stall` 132.5 ms、`switch.hugeProject.stall` 120.3 ms，三项通过；打包成功。R1、R2、R3 通过，不要重做。

只剩一件事。

## R4 两项启动指标：是这次改动带来的，要查清并消除

第 2 轮说明里我判断「启动超限不是这次改动造成的」，那是在负载 70+ 时下的结论，**是错的，以本节为准**。
负载正常时在同一小时内对照，没改过的 0.15.0 是达标的：

| 中位数（ms），各 5 轮 | 上限 | 0.15.0 基线 | 当前，原样 | 当前，项目列表只放小仓库 | 当前，只放小仓库且不包成临时 App |
|---|---|---|---|---|---|
| launch.repoLoaded | — | 556.7 | 546.4 | 576.2 | 504.4 |
| launch.diffReady | — | 885.0 | — | 932.3 | 841.7 |
| launch.firstContentFrame | 1100 | **938.3** | **1305.5** | 1261.8 | 1118.2 |
| launch.treeReady | — | 1036.9 | — | 1445.6 | 1328.4 |
| launch.readerPainted | 1450 | **1274.2** | **1664.3** | 1717.6 | 1543.6 |

从这张表能确定的：

- 和项目列表里多出来的两个大仓库无关（去掉它们没有变化）。
- 包成临时 App 占了大约 100–150 ms。
- 其余的差距出在 `launch.diffReady` 之后：到 `firstContentFrame` 基线只要约 50 ms，当前要约 280 ms，后面的里程碑整体后移。

一条线索（没有证实）：两边启动时恢复的不是同一个文件。当前恢复的是 `docs-progress-large.md`（85 KB），基线恢复的是
`docs/优化计划-2026-10.md`（24 KB）。`FolmiModel+PerfRun.swift` 结尾新加的「Keep the original reader scenario as the next launch's saved state」
改变了每一轮退出时保存的状态，下一轮启动恢复的内容就不一样了，启动指标也就不可比。

要做的：

1. 让每一轮 `--perf-run` 退出时保存的状态和 0.15.0 的脚本**完全一致**（同一个选中的改动文件、同一个打开的文档、同一个侧栏页、同一种阅读模式），
   大项目的往返测量不能在保存的状态里留下任何痕迹。用两边 `run-N.tsv` 开头的时间线对照确认恢复的是同一个文件。
2. 这样之后重测。如果 `firstContentFrame` 仍然比基线高 50 ms 以上，继续二分：先去掉 `runPerfScript` 开头新加的
   `makeKeyAndOrderFront` / `NSApp.activate`（只保留到确实需要它的那一步之前），再看 `ChangesPane` 里新加的
   `.task(id: revealKey)`、`.onChange(of: selectionRevealRequest, initial: true)`、`.transaction` 在小项目上是否多触发了一轮刷新。
   小项目（500 个文件以内）启动时，这次改动不应该多出任何一次 `ChangesPane` 的重新计算。
3. 临时 App 那 100–150 ms：如果它确实来自首次运行新签名的程序（看 5 轮里是不是只有第 1 轮慢），就在计时的 5 轮之前先空跑一次预热，不计入结果；
   不是的话，报告原因。
4. 不要改两项启动指标的上限，不要改它们的打点位置。

基线的测法（供你对照）：`git worktree add --detach <临时目录> HEAD`，在里面先 `./scripts/perf.sh 2` 预热，再 `./scripts/perf.sh --budget 5`，
用完 `git worktree remove --force`。基线的旧脚本在有别的 Folmi 在运行时测不到阅读页的几项，这没关系，只看 `launch.*`。

## 这一轮怎样算完成

和第 2 轮相同的五条命令，其中 `./scripts/perf.sh --budget 5` 在负载正常时 **10 项全部 ✓**。

## 这一轮的报告

1. 启动变慢的原因（分别占多少毫秒），证据是什么，怎么改的。
2. 同一小时内基线和当前的 `launch.repoLoaded / diffReady / firstContentFrame / treeReady / readerPainted` 中位数对照表。
3. `perf.sh --budget 5` 的「性能门槛」整段原文和测量时的负载。
4. 全部测试的退出码、失败行检索结果。
5. 没做到的、拿不准的地方。没有就写「没有」。

---

# 第 4 轮返工（2026-11-12）

第 3 轮复核：测试退出码 0、无失败行；大项目三项通过；打包成功。你找到的原因是对的：我上一轮的基线副本里没有被忽略的
`docs/progress-v0.5.md`，两边恢复的文档不一样，那次对照不公平。

但第 3 轮的处理不能接受：**把这份大文档从测量场景里去掉，等于放松了原有的两项启动门槛**（第三节写了「现有的 7 项门槛不要改」，
场景也是门槛的一部分）。而且去掉之后正好掩盖了一个真实的变慢。两边都带上这份文档、恢复的都是 `docs-progress-large.md`，各 5 轮，负载 8–12：

| 中位数（ms） | 上限 | 0.15.0 基线（带大文档） | 当前代码（带大文档） |
|---|---|---|---|
| launch.repoLoaded | — | 581.1 | 591.4 |
| launch.diffReady | — | 988.0 | 953.9 |
| launch.firstContentFrame | 1100 | **1072.7 ✓** | **1290.7 ✗** |
| launch.treeReady | — | 1210.5 | 1415.7 |
| launch.readerPainted | 1450 | **1427.8 ✓** | **1710.8 ✗** |

`diffReady` 之前两边一样；`diffReady → firstContentFrame` 基线 85 ms，当前 337 ms。恢复小文档时这个差距消失（你第 3 轮的数字），
所以是 `diffReady` 之后多出来的某些工作，代价随当前显示内容的大小增长。此前的对照已经排除了：项目列表里的两个大仓库、包成临时 App
（不包、只放小仓库时差距仍有约 190 ms）。

## R5 恢复大文档场景，找出并消除 `diffReady` 之后多出的约 250 ms

1. **恢复场景**：`scripts/perf.sh` 里把 `[[ -f docs/progress-v0.5.md ]] && cp docs/progress-v0.5.md "$repo/docs-progress-large.md"` 这一行原样加回去，
   注释也恢复成原来的意思（「one large document added」）。每轮退出时保存的状态要和 0.15.0 的脚本在**带大文档时**一致
   （基线恢复的是 `docs-progress-large.md`，用 `run-N.tsv` 里第一条 `reader.swift` 确认）。第 3 轮加的预热可以保留。
2. **基线的测法**：`git worktree add --detach <临时目录> HEAD`，然后 `cp docs/progress-v0.5.md <临时目录>/docs/progress-v0.5.md`，
   先 `./scripts/perf.sh 2` 预热，再 `./scripts/perf.sh --budget 5`，用完 `git worktree remove --force`。
3. **找原因**：对当前代码做二分，每一步都用带大文档的场景测 `diffReady → firstContentFrame`。优先怀疑的两处：
   - `ChangesPane` 里新加的 `.task(id: revealKey)` → `reveal` → 改 `@State`、`selectionRevealRequest = UUID()`，以及
     `.onChange(of: selectionRevealRequest, initial: true)`、`.onChange(of: model.snapshot?.fingerprint, initial: true)`：
     它们在启动时是否让窗口在第一帧之前多刷新了一轮（看 `PerfLog.body` 的计数，和基线的 `bodies` 行对比，不只看 `ChangesPane`，也看 `DiffPane` 等）。
   - `runPerfScript` 开头的 `makeKeyAndOrderFront` / `NSApp.activate`，以及 `PerfLog.beginScriptRun` 之前的调用顺序。
     如果原因在这里，它只影响测量：把它挪到确实需要的那一步之前，并用数字证明。
   如果两处都不是，继续二分到具体的改动为止。
4. **修掉**。500 个文件以内的项目，启动和切换文件时不应比 0.15.0 多任何一轮界面刷新；`reveal` 在所在文件夹本来就展开时不应改动任何状态。
5. 不要改任何上限、打点位置；不要再改测量场景的内容。

## 这一轮怎样算完成

和之前相同的五条命令，并且：

- `./scripts/perf.sh --budget 5`（带大文档）在负载正常时 10 项全部 ✓；
- 同一小时内测的带大文档基线和当前代码，`launch.firstContentFrame`、`launch.readerPainted` 的中位数相差都不超过 50 ms。

`switch.reader fromCode` 每轮只有一个样本，复核时有一轮出现过 1531 ms 的离群值（其余 68–99 ms）。这是原有指标本身样本太少，
不用你处理；如果它单独导致不过，重跑一次并如实报告两次的结果。

## 这一轮的报告

1. 原因：是哪一处改动、为什么代价随显示内容增长、各步二分的数字。怎么改的。
2. 同一小时内带大文档的基线和当前对照表（`repoLoaded / diffReady / firstContentFrame / treeReady / readerPainted`），以及两边 `run-N.tsv` 里启动阶段的 `bodies` 对比。
3. `perf.sh --budget 5` 的「性能门槛」整段原文和测量时的负载。
4. 全部测试的退出码、失败行检索结果。
5. 没做到的、拿不准的地方。没有就写「没有」。
