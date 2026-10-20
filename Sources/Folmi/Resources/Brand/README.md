# Folmi · D3 炭黑与琥珀

已选视觉为小写 **f 精灵**，主色炭黑 `#222429` 与琥珀 `#E9AA47`。保留双眼、小折耳、横臂和左卷尾，不使用紫色或森林绿。

## 可用资源

| 路径 | 用途 |
|---|---|
| `Folmi.icns` | 当前 macOS App 的 Finder、Dock、切换器图标；标准 10 个尺寸表示 |
| `AppIcon.iconset/` | 16、32、128、256、512 pt 的 1x / 2x PNG，最大 1024 px |
| `AppIcon.appiconset/` | 相同图像及 Xcode `Contents.json`，为后续 Xcode 工程准备 |
| `AppIcon-1024.png` | 透明外边距的 1024 px 图标导出 |
| `UI/folmi-mascot-{size}.png` | 16 / 20 / 24 / 32 / 48 / 64 / 128 / 256 / 512 / 1024 px 的透明精灵 |
| `MenuBar/folmi-{points}Template.png`、`...Template@2x.png` | 16 / 18 / 20 / 24 pt 单色模板，菜单栏图标用 18 pt（`AppResources.menuBarMark`，`isTemplate = true`） |
| `MenuBar/folmi-template.svg` | 菜单栏简化矢量，与角色 SVG 共用几何 |
| `Mascot/folmi-mascot.svg` | 可编辑、可分层动画的正式角色源 |
| `Mascot/folmi-mascot-master.png` | 由 SVG 渲染的 1024 px 透明角色；导出产物，不直接编辑 |
| `Mascot/motion.json` | 八个动作状态、锚点、优先级、触发和减少动态约束 |
| `manifest.json` | 每张导出的尺寸、来源、透明通道、源文件 SHA256 及 ICNS 校验信息 |

## 来源和修改

`Source/folmi-d3-approved.png` 是用户批准的 D3 原稿，保持原文件。`Source/folmi-app-icon-master.png` 是用内置 imagegen 准备的透明正式图标母版；准确提示词和来源说明在 `Source/imagegen-prompts.json`。

角色的透明位图抠图曾出现红黄残边，已弃用。当前 UI、菜单栏和动画均以 `Mascot/folmi-mascot.svg` 为几何来源。它是为动效制作的简化矢量重绘，保留 D3 的角色特征，**并非生成图的像素级复刻**。因此不能用 UI PNG 替代正式 App 图标。

重新导出（macOS，无额外依赖）：

```sh
swift scripts/export-brand-assets.swift
./scripts/build-app.sh --preview
```

脚本路径相对项目根；导出器也可从其他目录以绝对路径运行。它只重采样图标母版、渲染角色 SVG、生成模板与 ICNS，并自动反解检查 10 个 ICNS 尺寸。源图或 SVG 改动后需要重新导出再打包。

`scripts/build-app.sh` 将 `Folmi.icns` 放到 App 主资源目录，并通过 `CFBundleIconFile` 引用。SwiftPM 同时复制整个 `Brand` 目录，可经 `Bundle.module` 访问。菜单栏图标是 18 pt 模板；有改动的项目时，旁边显示项目数。

## 动作预览

从项目打开 [品牌资源预览](../../../../docs/brand/index.html) 或 [小精灵动作室](../../../../docs/brand/folmi-motion.html)，配套 [动作规范](../../../../docs/brand/folmi-motion.md)。预览可离线使用，不发送请求、不执行终端命令。

动画设计已完成，尚未接到真实终端或 AI 生命周期。后续按 `motion.json` 由真实任务状态驱动；32 px 以下保持静止，尊重系统减少动态设置，放在预留配件位，不遮挡输出或夺取输入焦点。
