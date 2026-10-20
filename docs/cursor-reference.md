# Cursor 习惯参考与原生实现取舍

记录日期：2026-10-16。本轮依据用户授权，只读查看本机 Cursor 的编辑设置、快捷键及相关扩展制品，将可确认的习惯用于 Folmi。此文档区分设置事实、静态代码证据和本应用实现；不将静态分析当成插件运行验收。

本轮验证仅使用新建演示仓库和隔离的本应用配置。Cursor 设置、真实项目 Git 信息及 SmartGit 用户配置不作为写入或验证目标。没有将 Cursor 账户、凭据、工作区历史或插件运行时打包进本应用。

## 设置与快捷键

| Cursor 只读观察 | 本应用取舍 |
| --- | --- |
| JetBrains Mono，字号 18，行高 22，Tab 2，自动换行开启 | 「Cursor 习惯」预设采用相同字体、字号、行高、缩进和换行；字体不可用时回退到系统等宽字体。只保存本应用自己的设置。 |
| `editor.fontLigatures: true` | 记录为偏好；没有移植 VS Code 的字体渲染配置链，不承诺与 Cursor 的连字效果完全一致。 |
| 编辑主题 One Dark Pro | 从主题颜色定义参考本应用原生调色板，提供深色、浅色和跟随系统三种外观。 |
| Markdown 预览字号 16；Markdown Preview Enhanced 使用 `one-light.css` | 按用户进一步选择，改为原位编辑与排版共用一份文档、一套编辑字号和主题。没有建立独立字号 16 的 WebView 预览。 |
| `Cmd+D` 删除行 | 编辑器映射为删除当前行或所选行，保留原生撤销。 |
| `Option+Cmd+Down` 向下复制行 | 编辑器映射为向下复制当前行或所选行。 |
| `Shift+Option+M` 打开 Markdown Preview Enhanced 预览 | 本应用映射为 Markdown「原位 / 源码」切换；行为适配单编辑器结构。 |
| 本次新增要求 `Cmd+P`、`Cmd+Shift+F` | 分别用于快速打开项目文件和项目内全文搜索，不据此推断已读取到相同自定义绑定。 |

格式化、块注释、语言模式切换和 AI 相关绑定尚未移植。未导入完整 `settings.json`、`keybindings.json` 或安装 Cursor 的插件宿主。

## 扩展制品的证据范围

| 扩展 | 本轮制品与许可观察 | 已确认的内容与分析边界 |
| --- | --- | --- |
| One Dark Pro 3.20.3 | MIT；入口 `main` 4,077 B | REA 成功解析 1 个文件、526 个 AST 节点。另读取主题 JSON 参考颜色映射；本应用使用原生 `EditorPalette`，不执行扩展入口。 |
| Markdown Preview Enhanced 0.8.40 | NCSA；入口 `main` 16,926,445 B | REA 在 256 MiB / 30 秒约束下出现堆耗尽，没有获得完整 AST。随后只做静态定点源码检查，确认 WebView 预览及文档变化、选区同步相关路径。不能称为完整反编译，也没有验证插件运行效果。 |
| Mermaid 1.8.1 | 本轮关注其 TextMate grammar 注入 | 该制品为语法注入，不是独立的 Mermaid 语义渲染引擎；不能从其高亮配置推断本应用已能渲染流程图。 |

本应用没有复制或执行这些插件的 JavaScript 运行时，没有引入 WebView、插件宿主或新的 Markdown 渲染依赖。主题颜色参考与插件功能移植是不同范围。颜色参考附带 [One Dark Pro MIT 许可](../licenses/OneDarkPro-LICENSE.txt)，构建脚本会将它和 SwiftTerm 许可一起放入应用资源。

## Markdown 原位编辑的实际能力

底层仍是一份完整的 Markdown 字符串，由同一个 `NSTextView` 编辑与保存。原位排版只改变字体、颜色和段落属性，不删除、替换或重新排列源字符；源码模式直接展示同一份未保存文档。

支持标题、粗体、斜体、删除线、行内代码、链接文字、引用、列表和任务前缀、分隔线以及围栏代码。非活动块尽量收起标题、强调、行内代码和链接目标等标记；光标进入块后揭示源码，跨段选区会揭示全部涉及的块。围栏代码按完整块判断活动状态，代码内部的 `**` 不会误作 Markdown 强调。

列表和任务前缀保留低对比源码，未伪造可点击复选框。表格、图片、HTML 和 Mermaid 保留可读源码，未实现完整 Typora 的表格排版、图片显示、公式或图表渲染。链接只着色，不自动打开地址；不加载远程图片、运行 HTML 或脚本。

代码围栏复用本应用现有 JS/TS、Python、Swift、JSON、Shell 词法高亮与深浅色调色板。它属于词法着色，不是 TextMate、语法树或语言服务器。排版有 230 ms 防抖，输入法组合期间暂停，过期文档或选区结果不再应用。扫描限前 192 Ki UTF-16 单元，样式、标记和块合计最多 6,000 项，并设扫描工作预算；达到边界会提示有界排版，其余文本仍可编辑。

相关实现见 [MarkdownLive.swift](../Sources/Folmi/MarkdownLive.swift)、[EditorPresentation.swift](../Sources/Folmi/EditorPresentation.swift) 和 [FileEditor.swift](../Sources/Folmi/FileEditor.swift)。独立测试覆盖源文、选区、撤销、修改通知不受属性应用影响，以及 UTF-16、围栏、活动块、输入法、取消和深浅色边界；集成验收以本轮验证记录为准。

## 只读校验记录

以下为本轮读取时记录的 SHA-256 基线。交付前已再次计算并比对，两份文件均与基线完全一致。

| 文件 | SHA-256 基线 |
| --- | --- |
| Cursor 用户 `settings.json` | `da5dd6855734b734679962536f985410ec6b3981a7fd306f06f9e036d363e409` |
| Cursor 用户 `keybindings.json` | `0d8cf99e60b1073de12abf45bbd377230c9bc183302cf802decfdcf9d8a58a98` |

两个文件的哈希比对用于确认这两个文件的内容是否变化，不扩张为对整个用户目录或全部应用配置的全量快照声明。
