# 项目轨：项目图标

状态：已实现（2026-11-18）。实现和本稿不同的地方见文末「实现说明」。和 [agent-overview.md](agent-overview.md) 第一期的状态角标一起做，两者画在同一个方块上。

## 要解决什么

项目轨每个项目只画名字的首字母（`FolmiView.projectRow`，`project.name.prefix(1)`）。同时开着 `folmi`、`frontend`、`fastapi-server` 时，一排都是 `F`，只能展开项目轨或悬停才分得清。项目轨每天要看几百次，它应该一眼就能认出来。

## 范围

- 只改项目行（`RailEntry.project`）。工作树行（`worktreeProject`）保留分支图标，不找图。
- 不在用户的仓库里写任何文件。
- 不做 SF Symbol 选择器（第一期不做；Emoji 已经够区分）。

## 图标从哪来（按优先级）

1. **用户指定的**：拖进来的图片，或选的一个 Emoji。
2. **在仓库里找到的**：见下面「自动找图标」。
3. **生成的字母徽章**：找不到图时用。

### 自动找图标

只看 Git 跟踪的文件，不扫目录（不会进 `node_modules`、`.build`，大仓库也快）：

```sh
git ls-files -z -- <下面的候选路径规则>
```

候选按顺序取第一个能读出来的：

| 顺序 | 规则 | 常见于 |
| --- | --- | --- |
| 1 | `**/AppIcon.appiconset/*.png`（选边长最接近 128 的方图） | Xcode / SwiftPM App（Folmi 自己就在 `Sources/Folmi/Resources/Brand/`） |
| 2 | `**/*.icns` 里名字含 `AppIcon` 或和项目同名的 | macOS App |
| 3 | `public/favicon.svg`、`public/favicon.png`、`public/favicon.ico`、`src/app/icon.{svg,png}`、`app/icon.{svg,png}`、`app/favicon.ico`、`static/favicon.*` | Web 项目 |
| 4 | `logo.{svg,png}`、`icon.{svg,png}`、`assets/logo.*`、`assets/icon*.png`、`site/assets/icon*.png`、`docs/logo.*` | 通用 |
| 5 | `android/app/src/main/res/mipmap-*/ic_launcher.png`（取最大的） | Android / RN / Flutter |

- 路径深度不超过 6 层，跳过 `test`、`fixtures`、`examples`、`vendor`、`node_modules` 下的匹配。
- 用 `NSImage(contentsOf:)` 读；读不出来（比如某些 SVG）或不是接近正方形（宽高比超过 1.25）的，跳过换下一个，不报错。
- 读出来后缩成 64×64 pt（@2x，即 128 px）的 PNG 存进缓存（见「存储」），界面只读缓存。

### 什么时候找

- 后台做（`Task.detached(priority: .utility)`），**绝不阻塞启动或切换项目**。启动时先画缓存里的图，没有就先画字母徽章。
- 时机：添加项目时；启动后对每个项目各做一次（缓存超过 24 小时才重找）；右键「重新查找图标」。
- 缓存的 key 带上找到的文件路径和它的 blob id（`git ls-files -s` 给的），图标文件变了才重新缩图。

### 字母徽章

- **缩写**：按 `-`、`_`、`.`、空格和驼峰拆词。
  - 两个词以上：取前两个词的首字母，大写（`folmi-core` → `FC`，`myApp` → `MA`，`fastapi-server` → `FS`）。
  - 只有一个英文词：首字母大写加第二个字母小写（`folmi` → `Fo`，`frontend` → `Fr`）。
  - 首字符是汉字等非拉丁字符：只取第一个字（`验收台` → `验`）。
- **底色**：按 `rootPath` 算一个**稳定的**哈希（FNV-1a 或 SHA-256 取前几位；不能用 Swift 的 `hashValue`，它每次启动都变）选主题调色板里 8 种柔和底色之一，文字用对应的深色。四套主题各自定义这 8 种颜色（放进 `DesignTokens` / 主题定义里，深浅色都要好看）。
- 像素主题：缩写用像素字体，底色同样取调色板。

## 显示

- 方块大小不变（28×30 的格子），图片画 22×22，圆角 5，带 0.5 pt 的描边（`separator` 色，避免白底图标和浅色背景融在一起）。
- Emoji 画 17 pt 居中。
- 选中的项目和现在一样有选中底色；图片本身不变暗。
- 展开项目轨时，名字照旧显示在右边。

## 自定义

| 入口 | 行为 |
| --- | --- |
| 把图片文件（PNG、JPEG、SVG、ICO、ICNS、HEIC）拖到项目方块上 | 松手即换。方块在拖入时高亮。读不出来的文件不接收（拖入时就显示禁止） |
| 项目右键 →「更换项目图标…」 | 打开文件选择器，只能选图片 |
| 项目右键 →「使用 Emoji…」 | 弹出一个小输入框（可用 ⌃⌘空格 调出系统表情面板），只取第一个字符 |
| 项目右键 →「重新查找图标」 | 只在没有自定义图标时出现，立刻在后台重找一次 |
| 项目右键 →「恢复默认图标」 | 只在有自定义图标时出现；删掉自定义，回到自动找到的图或徽章 |

- 换图标不进 ⌥⌘Z 撤销栈（它不是 Git 操作），「恢复默认图标」就是回退。
- 拖入的图片当场缩好复制进缓存目录，原文件之后删掉或移动都不影响。

## 存储

- `ProjectPreferences` 新增 `customIcon: ProjectIcon?`：

  ```swift
  enum ProjectIcon: Codable, Equatable { case image(String) /* 缓存里的文件名 */, emoji(String) }
  ```

  `init(from:)` 里用 `decodeIfPresent`，旧配置读出来是 nil。
- 缩略图放在**设置文件所在目录**的 `project-icons/` 下（正式环境是 `~/Library/Application Support/Folmi/project-icons/`）。必须跟着 `RuntimeOptions.workspaceURL` 走，这样测试和 `--demo` 用的是临时目录，不碰真实设置。
  - 自定义：`custom-<sha256(rootPath) 前 16 位>-<时间戳>.png`。
  - 自动找到的：`auto-<sha256(rootPath) 前 16 位>.png`，再加一个同名 `.json` 记来源路径、blob id、找的时间。
- 从项目轨移除项目时删掉它的缩略图。
- 内存里按项目缓存 `NSImage`，滚动和切换项目不重复解码。

## 测试

- 缩写规则：上面的例子都覆盖，再加空名字、纯数字、Emoji 开头的名字。
- 底色哈希：同一路径两次结果相同（写死一个期望值，防止有人换成 `hashValue`）。
- 旧配置（没有 `customIcon`）能读；新字段写出再读回一致。
- 用 `DemoRepository.create()` 的仓库放几个候选文件，验证优先级、跳过 `node_modules`、跳过非方图。
- 自定义图片缩放后是 128×128 PNG。

## 不做

- 不往仓库写 `.folmi-icon` 之类的文件。
- 不联网找图标（不查 GitHub 头像、不取网站 favicon）。

## 实现说明

- 空名字显示 `?`，纯数字取前两位。Emoji 和其他非拉丁字符保留首个完整字符。
- 深度按目录层数计算。Android 的 `mipmap-*` 是第六层，下一段是文件名。
- 以 Git 索引里的路径和 blob ID 判定缓存是否重用，图片从检出的同名文件读取。相同候选和 blob 会复用上次的缩略图。没有匹配时也记下搜索时间，启动后同样按 24 小时检查，右键可以立即重查。
- 自定义图片等比缩放到透明的 128×128 PNG，长边填满。重新定位项目时，自定义图片随设置迁移到新路径对应的缓存名。
