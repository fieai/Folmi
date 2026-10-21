# 编辑器和终端：向左拆分 / 向右拆分

状态：第一期已实现（2026-10-21）。实现和本稿不同的地方见文末「实现说明」。

## 要解决什么

现在编辑器卡片一次只显示一个文件，终端卡片一次只显示一个标签。验收时常见的需要：

- 一边看 AI 改的文件，一边对照它调用的另一个文件（或同一个文件的两处）。
- 一个终端跑着 agent，另一个跑测试或 `git log`，想同时看到输出。

## 范围

- 只做**左右**拆分，不做上下、不做嵌套。编辑器和终端本来就是上下排的，再上下拆空间不够。
- 每张卡片最多拆成 **3 栏**。
- 编辑器卡片里，「编辑」和「差异」可以放进栏里（见「差异栏」）；全部改动、历史仍是整张卡片一页。
- 文件与改动（左侧栏）不拆。

## 概念：栏

一张卡片里横向排着 1–3 **栏**。每栏有自己的一排标签和自己选中的那个标签；卡片标题栏（模式切换、最大化、收起）仍只有一个，属于整张卡片。

- 编辑器：每栏是一组打开的文件。同一个文件可以同时在两栏打开，**内容共享**（改一边，另一边立刻同步，保存一次即可），光标和滚动位置各自独立。
- 终端：每栏是一组终端标签，每个 shell 只属于一栏。「AI」标签固定在最左一栏。

始终有一栏是**当前栏**（标签行顶部一条强调色细线标出），点哪栏哪栏就是当前栏。

## 怎么拆、怎么合

| 入口 | 行为 |
| --- | --- |
| 标签右键 → 向左拆分 / 向右拆分 | 在当前栏左/右新开一栏，把这个标签**移过去**（编辑器：同一文件在新栏再开一份，原栏保留；终端：shell 移过去，原栏少一个标签） |
| 卡片标题栏的拆分按钮（`rectangle.split.2x1`），点开菜单：向左拆分 / 向右拆分 | 同上，作用于当前栏选中的标签 |
| ⌘\\ | 向右拆分当前标签（编辑器、终端都是，按焦点所在卡片） |
| ⌥⌘\\ | 向左拆分 |
| 标签右键 → 移到左边一栏 / 移到右边一栏 | 只在已拆分时出现 |
| 拖标签到另一栏的标签行 | 移过去（第二期，见下） |
| 每栏标签行最右侧的 × | 合并这一栏：它的标签并入左边一栏（最左一栏则并入右边），**不关闭任何文件或 shell** |

终端拆分时如果当前栏只有一个标签：向右拆分会**新开一个 shell** 放到新栏，而不是把唯一的标签挪走留下空栏。编辑器同理，复制一份当前文件到新栏。

### 什么时候不能拆（按钮置灰并写明原因）

- 已经 3 栏：「最多拆成 3 栏」。
- 卡片宽度放不下：每栏编辑器至少 320pt、终端至少 240pt，不够时置灰：「窗口太窄，放不下再一栏」。
- 编辑器在全部改动或历史页：菜单项写「切到编辑或差异页后可以拆分」。

窗口缩窄到放不下现有栏数时，不自动合并，只把各栏压到最小宽度并让卡片横向滚动——用户的布局不被悄悄改掉。

## 差异栏

验收最常见的用法：左边看 AI 改了什么，右边直接改这个文件。

- 「差异」作为一种特殊标签放进栏里，标签名「差异 · 文件名」，图标同模式切换里的差异。**整张卡片最多一个差异标签**：差异的内容始终是左侧改动列表里选中的那些（`model.fileDiffs`），只有一份。
- 差异工具条加一个按钮「在旁边编辑」：在右边一栏打开这个文件，并跳到差异里当前那一处对应的行；没有右边一栏就向右拆分。这是差异栏最主要的入口。
- 在差异页按 ⌘\ / 标签右键拆分：差异留在原栏，旁边新开一栏，打开差异里的文件（多选时是第一个）。
- 有差异栏时，点左侧改动列表里的文件只更新差异栏，**不动编辑栏**；编辑栏跟着切换文件需要在差异里点「在旁边编辑」，避免正在改的文件被换走。
- 模式切换：有差异栏时，点「差异」/「编辑」只是把当前栏切到差异栏或最近用过的编辑栏，不离开分栏；点「全部改动」/「历史」整张卡片切过去，分栏布局保留，切回编辑或差异时原样恢复。
- 在编辑栏保存后，差异栏照常刷新（现在保存就会刷新快照，无需另做）。
- 关闭差异标签：差异栏变回普通编辑栏（栏里没有其他标签时合并掉）。
- 收下、丢弃、按行勾选等操作仍在差异栏里做，行为不变。

## 尺寸

- 栏之间用现有的 `PaneResizeHandle`（横向）拖动，双击恢复等分。
- 宽度按比例存（`[Double]`，和为 1），这样窗口大小变了比例不变。
- 卡片最大化（⇧⌘↩）时，整张卡片连同所有栏一起最大化。

## 焦点和已有功能的去向

拆分后很多「对当前文件 / 当前终端」的操作要明确落到哪一栏：

| 操作 | 落点 |
| --- | --- |
| ⌘S 保存、⌘W 关标签、Markdown 阅读/编辑切换、大纲、自动换行 | 当前栏选中的文件 |
| 从文件树、改动列表、搜索结果、终端 ⌘ 点击打开文件 | 文件已在某栏打开 → 切到那栏；否则开在当前栏 |
| 发送选中内容到终端（`sendEditorSelectionToTerminal`）、`cd` 到文件夹 | 终端的当前栏选中的标签 |
| ⌘2 / ⌘3 聚焦卡片 | 聚焦这张卡片的当前栏 |
| 新建终端标签（⌃⇧\`） | 加在终端当前栏 |
| 外部改动提示、恢复上次会话 | 按文件，所有栏同时处理 |

## 数据结构

不在 Git 之外另记状态，布局只是界面偏好。

```swift
/// One column of a split card: its tabs in order and which one is selected.
struct PaneGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var tabs: [String]      // editor: document ids (paths), plus "folmi:diff" for the one diff tab; terminal: session ids
    var selected: String?
}

struct SplitLayout: Codable, Equatable {
    static let maxGroups = 3
    var groups: [PaneGroup]
    var fractions: [Double]  // same count as groups, sums to 1
    var active: Int
    mutating func split(_ tab: String, from group: Int, toRight: Bool, copies: Bool)
    mutating func move(_ tab: String, to group: Int)
    mutating func merge(_ group: Int)   // tabs go to the neighbour, nothing closes
}
```

- `EditorWorkspace`：`documents` 不变（一份文件一份文本），新增 `layout: SplitLayout`；`selectedDocumentID` 改为计算属性 = 当前栏的选中；`tabStates` 的 key 从 document id 变成 `(groupID, documentID)`，让两栏各自记光标和滚动。
- 终端：`terminals[root]` 不变（所有 shell），新增 `terminalLayouts[root]: SplitLayout`；`terminalSession` 改为当前栏的选中。
- 持久化：`ProjectPreferences` 加 `editorGroups`、`terminalGroups`（存路径 / 标签序号和比例），`init(from:)` 里 `decodeIfPresent`，缺省为一栏、包含全部标签——旧配置读出来就是现在的样子。保存前校验路径安全，和 `editorTabs` 的现有校验一致。
- 纯状态的 `SplitLayout` 单独写测试（拆、移、合、越界、合并后 active 落点），不需要开窗口。

## 视图

- `EditorCardPage` 的「编辑」分支：`HStack` 里每栏一个 `EditorTabStrip + FileEditorPane`，二者改为接收 `groupID`。`FileEditorPane` 内对 `selectedDocument` 的读写都换成「这一栏的选中」。
- `TerminalCard`：标签行按栏拆开，内容区 `HStack` 每栏一个 `TerminalPane`。`TerminalHostView.adopt` 已支持把同一个 `FolmiTerminalView` 换到新的宿主里，移动 shell 不会重启进程。
- `PaneFocusTracker`：锚点从「每张卡片一个」变为「每栏一个」（`(FolmiPane, groupIndex)`），点击时同时更新卡片焦点和当前栏。
- SwiftUI 表达式会变大：每栏拆成独立的 `EditorGroupView` / `TerminalGroupView`，避免 type-check 超时。

## 分期

1. **第一期**：`SplitLayout` 和测试；编辑器、终端的右键拆分 / 移动 / 合并、拆分按钮、⌘\\、⌥⌘\\；差异栏和「在旁边编辑」；尺寸拖动；持久化；焦点落点。
2. **第二期**：拖标签到另一栏；拖到卡片左右边缘直接拆分（边缘出现半透明落点提示）。
3. 写进 `CHANGELOG.md` 的「未发布 → 新增」，跑 `scripts/site-changelog.py`。

## 已定（2026-10-21）

1. 第一期就支持一栏看差异、一栏编辑（见「差异栏」）。
2. 同一个文件可以开在两栏，内容共享，光标和滚动各自独立。
3. 每张卡片最多 3 栏。

## 实现说明

- 差异做成一种**栏**（`PaneColumn.isDiff`），不是放在标签行里的标签：差异栏没有标签，整张卡片最多一个，也不能往里移标签。关闭旁边唯一的文件栏时，差异栏一起去掉，差异回到整张卡片。
- `active` 只指文件栏；差异栏是不是当前栏由 `model.content == .diff` 决定，这样原来所有「差异页」的快捷键和按钮不用改。
- 同一个文件开在两栏时，两栏各自的光标和滚动在屏幕上是独立的；切走再切回这个标签时，回到两栏里最后一次的位置（`tabStates` 仍按文件记）。
- 「阅读 / 编辑」（Markdown）仍是整个编辑器一个开关，两栏一起切。
- 不拆分时，终端的标签仍在卡片标题栏；拆分后每栏有自己的标签行，标题栏只留「终端」。
- 代码：`PaneColumns.swift`（纯状态）、`FolmiModel+Split.swift`（操作）、`SplitColumnsViews.swift`（视图），测试在 `PaneColumnsTests.swift`。

