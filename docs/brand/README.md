# Folmi 品牌资源

本轮采用 D3「炭黑＋琥珀」f 精灵，交付 App 图标、透明角色、小尺寸模板和八状态动作设计。

- [打开资源预览](index.html)
- [打开可播放动作室](folmi-motion.html)
- [动作设计与后续接入规范](folmi-motion.md)
- [完整资源清单与重新导出方式](../../Sources/Folmi/Resources/Brand/README.md)

预览使用相对文件路径，可直接打开 HTML。受宿主浏览器策略限制时，可在项目根运行 `python3 -m http.server 8874 --bind 127.0.0.1`，然后访问 `http://127.0.0.1:8874/docs/brand/index.html`。

正式 App 图标已接入打包。动作室只演示角色状态和摆放方式，不连接真实终端、AI、仓库，也不执行预览中的命令。

App 对外身份统一为 **Folmi**：正式构建输出 `dist/Folmi.app`，预览构建保留 `Folmi-Preview.app` 等后缀；窗口、菜单栏面板与 App 元数据使用同一名称。主程序为 `Folmi`，helper 为 `folmi-hook`，Bundle ID 使用 `local.folmi.*`，链接使用 `folmi://`，个人数据目录为 `~/Library/Application Support/Folmi`，MCP 注册名为 `folmi`。

Swift 包、模块与源码目录统一为 `Folmi`、`FolmiCore`、`FolmiHook`，仓库本地审阅数据放在 `.git/folmi/`。旧名称（Git 工作台 / GitWorkbench）的兼容代码已全部删除。

默认主题已由「靛石」调整为「琥珀」，深浅两种模式都用图标同款 `#E9AA47` 主色与炭黑按钮文字，链接、选区和代码颜色同步去掉原来的靛蓝。浅色链接使用更深的琥珀色，以保持可读性。已保存的 `indigo` 主题 ID 保留兼容，原选择会直接使用新配色。其他主题独立保留。

此前的主题与名称验证记录：`./scripts/test.sh --filter ThemeTests` 8 项通过；`./scripts/build-app.sh` 正式打包与签名验证通过。使用隔离配置和临时演示仓库，在原生 App 中核对深浅主题、主按钮、编辑器、终端，以及系统菜单的 `About Folmi` / `Quit Folmi` 名称。截图为 [深色](folmi-theme-dark.png) 与 [浅色](folmi-theme-light.png)，验证未执行 Git 提交。这些结果不覆盖本轮身份与数据迁移改动。

此前的资源检查记录：40 张导出 PNG 的尺寸、透明与可见像素；8 张菜单栏模板的纯黑透明像素；ICNS 反解 10 个尺寸；本地链接；八个预览状态、暂停、减少动态和背景切换；`./scripts/build-app.sh --preview` 的 release 构建，以及生成 App 的 plist、图标一致性和签名验证均通过。当时未运行完整业务测试，也未把动效接到真实任务；这些结果不覆盖本轮身份与数据迁移改动。
