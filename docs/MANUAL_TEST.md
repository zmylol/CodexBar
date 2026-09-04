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
scripts/send-test-event action /absolute/path/to/project-alpha
scripts/send-test-event attention /absolute/path/to/project-beta
scripts/send-test-event ready /absolute/path/to/project-gamma
```

确认：

- 悬浮条默认只显示三个项目名和状态颜色；
- 鼠标悬停 `project-alpha` 时显示任务摘要、状态、时间和“运行 Swift 测试”节点；
- 保持悬停并再次发送 `action`，节点时间和内容应实时更新，不需要移开鼠标重新打开；
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
3. 悬停工作中的项目，确认最多动态显示三个“读取 / 搜索 / 修改 / 测试 / 命令”节点；不得显示原始命令、补丁、搜索词或工具输出。
4. 在同一项目提交下一次任务，确认旧节点立即清空，新动作到达后才重新出现。
5. 出现授权请求的项目显示“需要处理”。
6. turn 停止后显示“可查看”，而不是“已完成”，并保留该 turn 最后的三个节点供当前运行期间查看。
7. 切换到其他应用并点击对应项目，确认原窗口被准确恢复，其他 VS Code 窗口最小化。
8. 完全退出并重新启动 CodexBar，确认任务状态能被保守恢复，但活动节点为空；无法唯一匹配的历史任务不得出现。

## 客户端来源隔离验收

1. 保持 CodexBar 与 VS Code 正常运行，在 VS Code Extension 中提交一个中性测试任务，确认悬浮条出现对应项目。
2. 在其他 Codex 客户端中使用不同目录提交任务，确认悬浮条、`Inbox`、`Activity` 和 `Probe` 都不新增对应事件。
3. 在终端 Codex CLI 中使用第三个目录提交任务，确认同样不会出现对应事件或任务。
4. 退出并重启 CodexBar，确认来源缺失或属于其他客户端的升级前旧任务不再显示。
5. 点击保留下来的 VS Code 任务，确认只尝试切换既有 VS Code 窗口；即使未找到窗口，也不会打开其他应用或创建窗口。

## 删除与启动恢复验收

1. 在 VS Code Extension 中启动一个 turn，保持“执行中”时从悬浮条删除该行，然后重启 CodexBar；同一 task ID 不得被启动恢复重新加入。
2. 在同一目录提交一个具有新 turn ID 的 VS Code 任务，确认新行可以正常出现。
3. 在系统统一日志中模拟一次启动恢复 App Server 不可用，确认错误消息不包含项目名、cwd、prompt 或 session/turn ID，且不会反复记录。

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
