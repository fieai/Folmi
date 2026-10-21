@AGENTS.md

## 只针对 Claude Code

- 项目说明都在 AGENTS.md（上面引用了），改约定时改那里，这里只放 Claude Code 才需要的内容。
- 跑完整测试大约要 2–3 分钟，放在后台运行，把输出写进文件，再 grep `\.swift:[0-9]+: error:` 看失败；不要只看 `tail`。
- 界面改动做完，用 `./scripts/build-app.sh` 打包后再说「做好了」；这个 App 不能在浏览器里预览。官网（`site/`）可以：`.claude/launch.json` 里的 `site` 配置会在 8765 端口起一个静态服务。
- 推送、部署官网、发版（`ship.sh`）都是对外的操作，要用户明确说了才做。
