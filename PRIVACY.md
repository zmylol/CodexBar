# CodexBar Privacy

CodexBar 是本地运行的开源工具。CodexBar 本身没有遥测、分析服务、账号系统或主动上传数据的网络客户端。

它会启动官方 VS Code Extension 中经过 OpenAI 签名验证的本地 `codex app-server` 子进程，以恢复已打开窗口对应的任务元数据。该官方组件及 Codex 服务本身的数据处理不由 CodexBar 控制；请同时查阅你所使用的 OpenAI 产品条款和隐私说明。

## 收集和保存的数据

Codex Hook 事件可能包含：

- session ID 和 turn ID；
- 当前工作目录的绝对路径；
- `UserPromptSubmit`、`PreToolUse`、`PermissionRequest` 或 `Stop` 事件类型；
- prompt 第一行的脱敏摘要，最多 80 个字符；
- 工具名称；
- 事件时间；
- assistant message 是否存在的布尔值。

CodexBar 不保存完整 prompt、完整 assistant message 或 transcript。assistant message 正文不会被解码到持久化模型；只保存“是否存在”。事件去重 ID 只基于已经过长度校验和脱敏的必要字段，不对原始 JSON、原始 prompt 或 assistant message 正文做持久化指纹。

启动历史恢复最多扫描 500 条来源为 `vscode` 的未归档 thread 元数据。存在活跃任务期间的节流核对不做全局扫描，只按现有任务的 session ID 读取元数据，每轮最多核对 128 个 `vscode` 或 `cli` thread。请求使用不加载 items 的模式。启动恢复只保存唯一匹配到已打开窗口的必要字段；周期核对只接受与已有任务的 session ID、turn ID 和 cwd 全部相同的快照。两条路径都不会保存 transcript 或 items，也不会重新加入已被用户删除的 task ID。

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

- `Inbox`：生命周期事件等待应用处理；成功后移动到 `Processed`，损坏事件移动到 `Failed`。
- `Activity`：最多 12 个脱敏后的临时动作事件；同一工作区的新 prompt 会替换旧队列，成功处理后直接删除，不归档。
- `Processed`、`Failed`、`Probe`：每个目录最多 500 个普通文件，且最长保留七天。新归档会立即触发轮转；应用正常运行时首次轮询及之后最多每小时再检查一次。
- `tasks.json`：当前任务可由用户删除或通过界面清理；用于防止重复处理的事件 ID 独立保留，最多 100,000 个。为防止旧快照在重启后复活已删除行，文件还会保留最多 10,000 个精确 task ID 与删除时间；最旧记录超限时移除。完整数据清除会删除整个文件。
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
