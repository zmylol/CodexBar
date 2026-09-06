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
- 鼠标悬停 `project-alpha` 时打开会话预览；模拟会话没有真实正文时显示读取提示及任务摘要；
- 保持悬停并再次发送 `action`，摘要提示可更新；模拟 Hook 不应生成虚假的正文或工具输出；
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

1. 关闭一个目标窗口，收到系统窗口通知后对应项目和正在显示的详情应自动收起；最小化窗口时项目仍保留。
2. 打开两个标题都匹配同一项目名的窗口，应提示歧义，不得切换。
3. 关闭全部 VS Code 窗口（进程可以继续运行）或退出 VS Code，列表应自动变为空状态；点击刷新仍应保持为空并报告未发现窗口。
4. 重新打开项目窗口，已有任务状态应自动恢复；此前从菜单明确删除的任务不得复活。
5. 快速连续开关窗口，确认最终列表与当前窗口一致；窗口读取失败或辅助功能权限暂时不可用时，不得把已有列表误判为空。
6. 在系统设置授予辅助功能权限后切回 VS Code，确认监听自动恢复；启动时没有窗口的 VS Code 进程，稍后新建窗口也应被检测到。
7. 空闲放置后再发 Hook，确认文件写入立即触发任务更新；手动刷新同时重试监听与待处理事件。监听失败应显示提示，不得静默改用定时轮询。

## 显示模式

1. 打开至少六个已有任务的 VS Code 项目，从右上角三点菜单选择“显示模式 → 自动展开”；所有项目应直接显示，面板向下增高且没有滚动区域。
2. 切换“固定高度（滚动）”，确认恢复最多五行，滚动可以访问其余任务；重启 CodexBar 后保持所选模式。
3. 将面板移到屏幕底部后切换为自动展开，再开关项目；面板应保持在屏幕可用范围内，项目超过屏幕容量时仍能滚动访问。
4. 将面板移到较小屏幕或断开外接屏幕，确认任务和菜单仍可访问；用键盘和 VoiceOver 检查模式名称及当前选中状态。

## 真实 Codex 三窗口验收

1. 在 `project-alpha` 和 `project-beta` 分别提交真实 Codex 任务；其中一个任务应足够明确地拆成至少五个计划步骤。
2. 工作中的项目显示“执行中”。
3. 持续悬停项目，确认显示该会话的用户消息、助手正文和工具条目。助手增量文字无需重新悬停即可更新；用户长消息可展开，Markdown 标题、强调、列表和代码可读。
4. 展开命令与工具，核对完整输入、最终输出、失败状态及非零退出码。运行中输出允许在工具完成或展开刷新后补齐，不得把工具输入冒充输出。确认长输出可滚动、选择和复制，顶栏与底部按钮固定且屏幕较小时仍可访问。
5. 向上阅读并等待新内容，位置不得跳到末尾；点击“回到最新”应恢复跟随。加载较早内容后应保持原阅读位置。切换项目、快速关闭重开时不得显示另一会话内容；同项目新 turn 继续追加在该会话历史之后。
   长会话首次只显示末尾一批，上滚接近顶部会加入较早内容；也可用键盘操作“显示较早内容”按钮。持续向上翻阅应能到达已收到的首条消息，本地前文全部显示后才出现网络历史加载入口。等待新的状态事件时，正文没有变化的卡片不应重复排版。
6. 出现授权请求的项目显示三角形“需要处理”；允许一个长命令后，在工具仍执行时立即恢复圆形“执行中”。拒绝后继续执行也应恢复。同一轮再次请求授权、并行审批只处理一项、等待期间重启 CodexBar 后再处理均应正确同步。顶栏始终完整显示 CodexBar。
7. turn 停止后显示“可查看”，而不是“已完成”，并冻结该 turn 最后的计划或动作供查看。
8. 切换到其他应用并点击对应项目，确认原窗口被准确恢复，其他 VS Code 窗口最小化。
9. 完全退出并重新启动 CodexBar，确认任务状态能被保守恢复，正文在再次打开预览后重新读取；无法唯一匹配的历史任务不得出现。断线时已有正文保留且提示不可用，重试或重连后可恢复。
10. 不使用鼠标，以键盘聚焦任务行，确认出现同一预览；按右方向键或从任务菜单选择“查看会话预览”进入卡片，方向键及翻页键可滚动，Tab 可到达展开与底部按钮，Escape 关闭并返回任务栏。开启 VoiceOver 后应能区分消息角色、工具状态及展开状态。鼠标进入卡片或键盘进入详情后仍保留可见，不被偶然划过其他行替换。
11. 分别在浅色、深色、Increase Contrast、Reduce Transparency 和较大文字设置下检查正文；任务内容完整换行，三种状态图标清晰。关闭预览后确认正文没有进入 `tasks.json` 或事件归档。

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
