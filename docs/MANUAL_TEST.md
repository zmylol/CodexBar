# CodexBar 人工验收

这份清单覆盖自动化无法证明的真实 IDE Hook、悬浮 UI 和 Accessibility 窗口操作。发布前应在干净用户环境中完整执行。

## 前置条件

- macOS 13 或更高版本；
- 官方 Visual Studio Code Stable；
- 官方 OpenAI Codex IDE Extension；
- 三个目录名不同的中性测试项目：`project-alpha`、`project-beta`、`project-gamma`；
- 三个项目分别在独立 VS Code 窗口打开；
- `scripts/test` 已通过；
- 已按 [HOOK_COMPATIBILITY.md](HOOK_COMPATIBILITY.md)完成 Probe 并切换到正式 Inbox。

## 悬浮条与本地模拟

```sh
open "$HOME/Applications/CodexBar.app"
scripts/send-test-event running /absolute/path/to/project-alpha "Refactor authentication hooks"
scripts/send-test-event attention /absolute/path/to/project-beta
scripts/send-test-event ready /absolute/path/to/project-gamma
```

确认：

- 悬浮条默认只显示三个项目名和状态颜色；
- 鼠标悬停项目时才显示摘要、状态和时间；
- 鼠标离开、按本地 Escape 或详情失去触发条件后，详情消失；
- 切换到其他应用后悬浮条仍可见，但不抢键盘焦点；
- 拖动后位置在重启应用后保留；
- 菜单可以删除单条、清除已读和清理旧任务。

## Accessibility 与窗口切换

第一次点击项目时，按系统提示前往：

```text
System Settings → Privacy & Security → Accessibility → CodexBar
```

授权后，保持 Safari 或其他应用在前台，依次点击三个项目并确认：

- 目标 VS Code 窗口被恢复并前置；
- 另外两个标准 VS Code 窗口被最小化；
- 目标窗口中原本打开的页面保持不变；
- 没有新建或重复 VS Code 窗口；
- ready 项只在成功切换后被标记已读。

失败关闭场景：

1. 关闭一个目标窗口后点击对应项目，应提示未找到窗口，不得新建窗口。
2. 打开两个标题都匹配同一项目名的窗口，应提示歧义，不得切换。
3. 退出 VS Code 后点击项目，应提示 VS Code 未运行。

## 真实 Codex 三窗口验收

1. 在 `project-alpha` 和 `project-beta` 分别提交真实 Codex 任务。
2. 工作中的项目显示“执行中”。
3. 出现授权请求的项目显示“需要处理”。
4. turn 停止后显示“可查看”，而不是“已完成”。
5. 再提交一个任务并手动点击停止；即使没有 `Stop` Hook，也应在下一次 App Server 核对后从“执行中”变为“可查看”。
6. 切换到其他应用并点击对应项目，确认原窗口被准确恢复，其他 VS Code 窗口最小化。
7. 完全退出并重新启动 CodexBar，确认已打开窗口的任务能被保守恢复；无法唯一匹配的历史任务不得出现。

## 终端 CLI 与删除恢复验收

1. 在终端进入 `project-gamma`，启动真实 Codex CLI 并提交任务，确认悬浮条显示“执行中”。
2. 手动中断该 turn；即使没有 `Stop` Hook，也应在下一次五秒节流核对后显示“可查看”并成为未读。
3. 再启动一个 CLI turn，保持“执行中”时从悬浮条删除该行，然后重启 CodexBar；旧行不得被启动恢复或周期核对重新加入。
4. 在同一目录提交一个具有新 turn ID 的任务，确认新行可以正常出现。
5. 在系统统一日志中模拟一次 App Server 不可用，确认错误消息不包含项目名、cwd、prompt 或 session/turn ID，且不会每五秒重复记录。

## 卸载验收

在隔离测试账号或确认可删除数据的环境中运行：

```sh
scripts/uninstall-app
```

确认应用、CodexBar Hook handler 和安装的 Hook 可执行文件已移除，但 Application Support 数据仍存在。重新安装后再运行：

```sh
scripts/uninstall-app --purge-data
```

确认 `~/Library/Application Support/CodexBar/` 已删除，其他 Hook 保持不变。

## 发布记录

只记录版本组合和通过/失败结果。不要提交截图中的用户名、机器名、真实项目、绝对路径、prompt、Probe 内容或完整 session/turn ID。
