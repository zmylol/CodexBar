# CodexBar Architecture

## Data flow

```text
Codex Hook stdin
    ↓ codexbar-hook (bounded parse + sanitization)
Inbox/*.json + Activity/*.json (bounded to 12)
    ↓ background CodexEventSource worker
EventProcessor
    ├─ lifecycle → TaskStoreStorage actor (tasks.json) → Processed/
    └─ PreToolUse → MainActor LiveTaskActivityStore → delete Activity file
                         (current turn, at most 3 nodes, memory only)
    ↓ revisioned view state
MainActor TaskStore + LiveTaskActivityStore
    ↓ CodexBarAppModel
compact floating panel
    ↓ explicit user click
CodexTaskOpener
    ├─ VS Code → AccessibilityWindowActivator → existing window
    └─ Codex Desktop → verified app + codex://threads/<session-id>
```

启动时以及存在活跃任务期间还有一条只读恢复路径：

```text
official VS Code Extension
    ↓ verified OpenAI-signed codex executable
codex app-server
    ↓ bounded thread metadata
StartupTaskReconciler → TaskStore
```

启动历史恢复只查询 `vscode` 来源，并通过 cwd 与当前窗口标题保守匹配。活跃任务核对以五秒为最小间隔且只允许一个请求在途；它不依赖窗口枚举或全局历史扫描，而是按已有 session ID 执行 metadata-only `thread/read`，再用 `thread/turns/list(itemsView: notLoaded)` 核对最新 turn。返回的 session ID、turn ID、来源和规范化 cwd 必须与查询开始时的已有任务全部相同。该路径用于在手动中断没有 `Stop` Hook 时接收 App Server 终态；不会重新添加已删除行或覆盖更新的 Hook turn。

## Targets

- `CodexBarCore`：事件解析、脱敏、Inbox、状态机、持久化、App Server 恢复与窗口匹配；
- `CodexBarWindowing`：Accessibility 授权、VS Code 进程和窗口操作，以及 Codex 桌面端精确 thread 深链；
- `CodexBarApp`：AppKit/SwiftUI 悬浮条及用户交互；
- `codexbar-hook`：由 Codex Hooks 调用的静默、快速、fail-open 命令；
- `codexbar-tests`：无第三方测试框架的统一 Swift 测试可执行文件。

## Safety invariants

- Hook 不向 stdout/stderr 输出普通成功信息，也不改变 Codex 决策；
- 原始 stdin 有大小上限，持久化前只保留必要且脱敏的字段；
- `PreToolUse` 不保留原始命令、补丁、搜索词、MCP 参数或工具输出；只生成受限分类和安全路径摘要；
- 实时活动队列独立于生命周期 Inbox、全局最多 12 条且生命周期事件优先；界面最多保留当前任务三个内存节点，新 prompt 会替换旧节点，应用重启不会恢复；活动事件不改变任务状态、不写入 `tasks.json`，处理后不进入归档；
- 事件目录和文件分别使用 0700 与 0600 权限；
- 事件文件读取、移动和归档轮转在后台 actor 中串行执行；每批事件只提交一次任务快照、执行一次归档轮转；
- 任务快照加载、JSON 编解码、排序、写盘和文件系统路径匹配均在后台 actor 中完成；主线程只发布不落后的 revision；
- 旧任务清理只会原子删除与后台匹配前完整快照仍一致的条目，期间收到新事件的任务会被保留；
- 手工和批量删除与精确 task ID tombstone 在同一个任务快照中原子提交；启动恢复、周期核对和同一 turn 的后续 Hook 都不能使其复活；
- Application Support 根目录和任务快照拒绝符号链接，并在每次持久化前重新验证；
- Hook 配置只删除 executable 路径精确匹配的 CodexBar handler；
- VS Code 窗口只有唯一匹配时才能执行操作；
- VS Code 实时进程在发现和动作前都必须通过 Microsoft Team 签名要求；
- 桌面 thread 深链只会显式交给 bundle id 与 OpenAI Team 签名均通过验证的 Codex 应用；
- 不执行 `code -r`，不创建窗口，不猜测歧义目标；
- App Server 有可执行文件签名、symlink、响应大小、消息数和超时限制；
- App Server 恢复只读查询 thread/turn 元数据且不加载 items；只有启动历史恢复枚举现有窗口，只有用户明确点击后才会前置或最小化窗口；
- App Server 失败日志使用固定、无任务字段的消息，并以一分钟为最小间隔。

## Packaging boundary

`.build/` 和 `dist/` 只包含本机生成物，不属于源码发布面。`scripts/build-app` 生成 ad-hoc 签名的本机架构应用；正式二进制发布需要独立的 Developer ID 签名、公证、stapling、校验和与 provenance 流程。
