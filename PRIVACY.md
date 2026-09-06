# CodexBar Privacy

CodexBar 是本地运行的开源工具。CodexBar 本身没有遥测、分析服务、账号系统或主动上传数据的网络客户端。

它会启动官方 VS Code Extension 中经过 OpenAI 签名验证的本地 `codex app-server` 子进程，以恢复已打开窗口对应的任务元数据。该官方组件及 Codex 服务本身的数据处理不由 CodexBar 控制；请同时查阅你所使用的 OpenAI 产品条款和隐私说明。

## 收集和保存的数据

Codex Hook 事件可能包含：

- session ID 和 turn ID；
- 当前工作目录的绝对路径；
- `UserPromptSubmit`、`PreToolUse`、`PermissionRequest`、`PostToolUse` 或 `Stop` 事件类型；
- prompt 第一行的脱敏摘要，最多 80 个字符；
- 工具名称；
- 固定的来源标记（仅 `vscode`）；
- 事件时间；
- assistant message 是否存在的布尔值。

CodexBar 不保存完整 prompt、完整 assistant message 或 transcript。assistant message 正文不会被解码到持久化模型；只保存“是否存在”。事件去重 ID 只基于已经过长度校验和脱敏的必要字段，不对原始 JSON、原始 prompt 或 assistant message 正文做持久化指纹。

来源标记来自 VS Code Codex Extension 启动 Hook 时提供的 `CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_vscode`。CodexBar 在读取 stdin 前进行精确匹配；值缺失、不同大小写、包含额外空白或来自其他客户端时都会静默退出，不读取或写入事件，也不会根据 cwd、进程名或 transcript 猜测来源。

`PreToolUse` 的原始 `tool_input` 只在短生命周期 Hook 进程中解析，不会写入事件文件。CodexBar 只生成“读取 / 搜索 / 修改 / 测试 / 命令 / 子任务协作”分类，以及可安全展示的相对路径或文件名；不会保存原始命令、原始 tool-use ID、补丁正文、搜索词、MCP 参数或工具输出。协作类别只由精确工具名确定，不读取委派的 prompt、message、description 或 agent ID；彩色图标表示协作类别，不编码代理身份。为了跨进程交付，脱敏后的活动会短暂写入独立的 `Activity` 队列：全局最多 12 条，同一工作区的新 prompt 会删除旧队列，应用处理后立即删除且不进入 `Processed`。如果应用一直没有启动，最多 12 个脱敏事件会留到下次提交或应用处理。界面仅在内存中保留当前任务最近三个节点，下一次提交、删除任务或退出应用时即消失，也不会写入 `tasks.json`。

启动历史恢复最多扫描 500 条来源为 `vscode` 的未归档 thread 元数据，并且只保存唯一匹配到已打开 VS Code 窗口的必要字段。请求使用不加载 items 的模式，不会保存 transcript 或 items，也不会重新加入已被用户删除的 task ID。

审批恢复使用独立的临时关联元数据：工具调用 ID 的 SHA-256 值，以及工具名称与必要输入的 SHA-256 指纹。shell / 编辑只使用命令或补丁输入；MCP 使用按键排序且去掉顶层审批说明 `description` 的输入。原始值只在 Hook 进程中处理，不写入事件文件或任务快照。指纹用于区分并行调用，不表示用户已批准，也不读取 `tool_response`。含关联元数据的工具开始与完成事件使用可靠的 `Inbox` 队列，不受普通活动的 12 条上限裁剪；处理后立即删除。审批事件归档前移除关联元数据。关联状态仅保留在应用内存中，任务结束、替换或应用重启后清除。

实时审批状态通过当前用户已有的 Codex 本地 Unix socket 订阅，只跟随悬浮条可见任务的已知会话，不枚举其他会话，不启动 IPC 服务，也不发送执行或审批决定。该扩展内部接口没有只含状态的订阅选项，因此收到的临时帧可能包含完整会话正文。CodexBar 使用字段白名单提取会话、轮次、工作目录、版本及运行状态；正文不进入任务模型、日志或磁盘，帧处理后即释放。关闭对应窗口、删除任务或退出应用后取消跟随。跟随期间官方扩展可能保持该线程驻留；连接和状态变化由 socket、文件系统及窗口事件驱动，没有周期查询。接口版本不兼容或断线时保留 Hook 路径，刷新可以重新连接。

App Server 查询失败时，CodexBar 最多每分钟向 macOS 统一日志写入一条固定诊断。该消息不包含 session/turn ID、cwd、项目名、prompt、状态或错误正文。

应用还会用 macOS UserDefaults 保存悬浮条位置等界面偏好。

## 本地存储

默认目录：

```text
~/Library/Application Support/CodexBar/
├── Inbox/
├── Activity/
├── Processed/
├── Failed/
├── Probe/
├── AppBackups/
├── HookConfigBackups/
├── HookConfigOriginal/
├── bin/
└── tasks.json
```

CodexBar 管理的目录设置为 0700，事件、任务和 Hook 配置备份设置为 0600。其他以同一 macOS 用户身份运行的进程仍属于同一用户信任边界，理论上可以读取这些数据。

## 保留策略

- `Inbox`：已确认来自 VS Code 的生命周期事件等待应用处理；成功后移动到 `Processed`，损坏事件移动到 `Failed`。升级前遗留且无法证明来自 VS Code 的事件直接删除，不归档。
- `Activity`：最多 12 个已确认来自 VS Code、脱敏后的临时动作事件；同一工作区的新 prompt 会替换旧队列，成功处理后直接删除，不归档。无法证明来源的旧事件也会直接删除。
- `Processed`、`Failed`、`Probe`：每个目录最多 500 个普通文件，且最长保留七天。新归档会立即触发轮转；应用正常运行时首次轮询及之后最多每小时再检查一次。
- `tasks.json`：只保存 VS Code Extension 任务。升级时，旧快照只迁移明确标记为 `vscode` 的任务，并立即重写为不含客户端路由字段的 v2 格式；来源缺失或属于其他客户端的旧任务直接删除。用于防止重复处理的事件 ID 独立保留，最多 100,000 个。为防止旧快照在重启后复活已删除行，文件还会保留最多 10,000 个精确 task ID 与删除时间；最旧记录超限时移除。完整数据清除会删除整个文件。
- 损坏的任务快照：为了诊断而隔离保留，直到用户手动删除或使用完整数据清除。
- `AppBackups`：最多保留最近五个安装前应用备份。
- `HookConfigBackups`：最多保留最近十个 Hook 配置备份；`HookConfigOriginal` 只保存首次安装前的恢复基线。

任务列表中的“删除”会移除可见条目，并留下上述最小删除记录；它不会立即定位并删除归档中的历史事件。相同 task ID 的 Hook 或恢复快照不会重新显示，不同 ID 的新 turn 不受影响。归档会按上述七天/500 文件策略自动清理。

## Accessibility 权限

CodexBar 在用户明确点击项目时使用 Accessibility：

- 验证 VS Code Stable 的 bundle id 与 Microsoft Team 签名，并枚举其标准窗口和标题；
- 唯一匹配目标项目；
- 恢复并前置目标窗口；
- 最小化其他标准 VS Code 窗口。

应用启动恢复也会使用窗口标题来匹配已打开项目；执行窗口操作前会再次验证进程身份。CodexBar 不安装全局键盘监听，不读取或记录其他应用的键盘输入。

## 删除数据

默认卸载应用和 CodexBar 管理的 Hook，但保留本地数据：

```sh
scripts/uninstall-app
```

显式删除 Application Support 中的任务、事件和备份：

```sh
scripts/uninstall-app --purge-data
```

该操作不可恢复。界面偏好和 Accessibility 授权由 macOS 分开管理，需要时可另外执行：

```sh
defaults delete com.codexbar.CodexBar
tccutil reset Accessibility com.codexbar.CodexBar
```

如果使用环境变量把 CodexBar 数据改到其他位置，清理前应确认实际的 `CODEXBAR_SUPPORT_ROOT`。

## 脱敏限制

CodexBar 会移除控制字符，并尽力遮蔽常见 API key、token、密码、Authorization header、带用户信息的 URL 和常见 token 格式。这不是完整的秘密检测器。不要在 prompt、项目目录名或 Hook 配置中放置凭证。

## 问题报告

隐私或安全问题请按照 [SECURITY.md](SECURITY.md) 使用私密渠道报告，不要在公开 Issue 中附上真实事件文件、prompt、完整 ID 或绝对路径。
