# CodexBar Architecture

## Data flow

```text
Codex Hook process
    ↓ exact originator == codex_vscode; otherwise exit without reading stdin
codexbar-hook (bounded parse + sanitization)
Inbox/*.json + Activity/*.json (bounded to 12)
    ↓ filesystem notification → background CodexEventSource worker
EventProcessor
    ├─ lifecycle → TaskStoreStorage actor (tasks.json) → Processed/
    └─ PreToolUse → MainActor LiveTaskActivityStore → delete transient event file
                         ├─ update_plan: latest whole plan, at most 20 steps
                         └─ other allowlisted tools: at most 3 activity nodes
                         (current turn, memory only; hover shows at most 5 plan steps)
    ↓ revisioned view state
MainActor TaskStore + LiveTaskActivityStore
    ↓ CodexBarAppModel
compact floating panel
    ↓ explicit user click
AccessibilityWindowActivator → existing official VS Code window
```

启动、新打开项目窗口或手动刷新时还有一条只读恢复路径：

```text
official VS Code Extension
    ↓ verified OpenAI-signed codex executable
codex app-server
    ↓ bounded thread metadata
StartupTaskReconciler → TaskStore
```

启动历史恢复固定只查询并验证 `vscode` 来源，通过 cwd 与当前窗口标题保守匹配，再用 `thread/turns/list(itemsView: notLoaded)` 读取最新 turn 元数据。它不会执行周期性全局扫描，也不会重新添加已删除行或覆盖更新的 Hook turn。

窗口同步使用 `NSWorkspace` 的应用生命周期通知，以及 `AXObserver` 的窗口创建、销毁和标题变化通知。AX 注册与监听维护在独立的休眠 RunLoop 线程执行，收到事件后异步核对窗口；没有定时窗口扫描。监听注册失败只在当前事件后有限重试，之后提示手动刷新。从系统设置返回应用、切换空间或唤醒也会重新核对监听和授权。

`CodexInboxMonitor` 使用文件系统通知监听 Inbox 和 Activity，先注册监听再处理启动积压，并在每次通知后逐批排空。处理期间的新通知会留下待处理标记，避免遗漏；没有定时 Inbox 检查。手动刷新会重新注册监听并处理积压。关闭窗口只过滤可见任务，保留本地状态以便重开窗口恢复；读取失败保留最后一次成功的窗口清单。

`CodexRuntimeStatusMonitor` 只连接当前用户已有的 Codex IPC socket，为可见任务查找原会话 owner 并订阅 `thread-stream-state-changed` v11。`CodexRuntimeStatusReducer` 在后台按 revision 投影必要状态，缺失增量时重新请求快照；不保留聊天内容。原会话的审批等待标记决定三角形，恢复 active 后立即显示执行中，无须等待工具完成。实时状态仅更新 session、turn 和 cwd 精确匹配的既有行；Hook 批次处理后重新应用当前投影，避免延迟 Hook 覆盖实时状态。断线、owner 离开或取消跟随后丢弃投影，窗口/文件/客户端事件及手动刷新触发重连，无周期轮询。接口为扩展内部协议，升级时必须重新验证兼容性。

会话预览使用同一条已校验 owner/目标的连接。`ConversationPreviewWorker` 在后台只为当前展开的 session/cwd 维护 `CodexConversationPreviewReducer`，合并 snapshot 和 Immer patch，再发布给独立的 `ConversationPreviewStore`。canonical 历史与 live turns 合并为有序条目；同 revision 的快照仍接收，因为未广播的命令输出可能已变化。缺少基准或 revision 不连续时请求快照；正文预算 32 MiB，结构或预算超限明确失效。展示目标带 generation，切换前已排队的帧不能更新新预览。关闭预览释放正文，状态订阅继续独立运行；断线保留最后可见内容并标记不可用。

`TaskDetailCard` 使用 420×520 的首选尺寸并受屏幕可用范围限制，固定顶栏与底栏，中间只有一个原生 `NSScrollView`。正文支持基本 Markdown、文字选择、用户消息和工具展开。滚动位置由 AppKit 管理，阅读旧内容时暂停跟随，补入早期条目时补偿高度变化。点击加载历史只向当前 owner 发送 `thread-follower-load-complete-history` v2，并等待相应 revision，不执行任何 turn 操作。协议验证和已知输出限制见 [CONTENT_PREVIEW_VERIFICATION.md](CONTENT_PREVIEW_VERIFICATION.md)。

长会话首次只排版末尾 30 条，上滚接近顶部或点击本地前文按钮时再加入一批；起始位置按 item ID 保留，尾部新增不会挤走正在阅读的内容。所有已收到的正文仍在当前会话 reducer 内，分批只限制界面排版。状态投影同时返回已解析的 session ID，其他会话帧不再进入选中预览的正文解析。`ConversationPreviewStore` 只在可见内容变化时发布，revision 单独推进历史请求进度，同 revision 的新工具输出仍然更新。可用 `scripts/test-preview-performance` 复跑合成首开/更新基准与原生阅读行为检查。

## Targets

- `CodexBarCore`：事件解析、脱敏、Inbox、状态机、持久化、App Server 恢复与窗口匹配；
- `CodexBarWindowing`：Accessibility 授权、VS Code 进程和窗口操作；
- `CodexBarApp`：AppKit/SwiftUI 悬浮条及用户交互；
- `codexbar-hook`：由 Codex Hooks 调用的静默、快速、fail-open 命令；
- `codexbar-tests`：无第三方测试框架的统一 Swift 测试可执行文件。

## Safety invariants

- Hook 不向 stdout/stderr 输出普通成功信息，也不改变 Codex 决策；
- Hook 只接受精确的 `codex_vscode` originator；其他客户端、缺失值和变体均在读取 stdin 前静默退出；
- 原始 stdin 有大小上限，持久化前只保留必要且脱敏的字段；
- `PreToolUse` 不保留原始命令、补丁、搜索词、计划解释、MCP 参数或工具输出；普通动作只生成受限分类和安全路径摘要，`update_plan` 只保留脱敏截断后的步骤文字与三个已知状态；计划标题同时受字素数和 UTF-8 字节数限制；
- 普通实时活动队列独立于生命周期 Inbox、全局最多 12 条且生命周期事件优先；队列满时先淘汰普通动作、保留计划快照；每个任务最多保留三个普通动作和一份最多 20 步的最新计划。`CodexTaskDetailSummary` 为任务行辅助功能和正文不可用时的简要提示提供概览。工具开始事件不代表成功，计划完成也不代表整轮成功；新 prompt 会替换旧进度，Stop 后冻结，应用重启不会恢复；普通活动不改变任务状态、不写入 `tasks.json`，处理后不进入归档；
- 审批关联的 `PreToolUse` / `PostToolUse` 经可靠 Inbox 按顺序交付，处理即删。TaskStore 的内存关联器只用工具调用 ID 与必要输入的哈希匹配审批；对应工具完成且没有其他未解决审批时，才将已有任务从需要处理恢复执行中。无法唯一匹配、缺失事件、重启及超限均保守保留提示；关联器随持久化失败一起回滚，关联元数据不写入任务快照；
- 事件目录和文件分别使用 0700 与 0600 权限；计划只允许出现在精确的 `PreToolUse + update_plan` 临时事件中，不一致事件会直接删除；崩溃遗留且超过五分钟的受管 `.tmp` 会在现有目录扫描中清理；
- 事件文件读取、移动和归档轮转在后台 actor 中串行执行；每批事件只提交一次任务快照、执行一次归档轮转；
- 任务快照加载、JSON 编解码、排序、写盘和文件系统路径匹配均在后台 actor 中完成；主线程只发布不落后的 revision；
- 旧任务清理只会原子删除与后台匹配前完整快照仍一致的条目，期间收到新事件的任务会被保留；
- 手工和批量删除与精确 task ID tombstone 在同一个任务快照中原子提交；启动恢复和同一 turn 的后续 Hook 都不能使其复活；
- v1 任务快照只迁移明确标记为 `vscode` 的任务并原子重写为 v2；其他旧任务和无法证明来源的旧队列直接删除；
- Application Support 根目录和任务快照拒绝符号链接，并在每次持久化前重新验证；
- Hook 配置只删除 executable 路径精确匹配的 CodexBar handler；
- VS Code 窗口只有唯一匹配时才能执行操作；
- VS Code 实时进程在发现和动作前都必须通过 Microsoft Team 签名要求；
- 不执行 `code -r`，不创建窗口，不猜测歧义目标；
- App Server 有可执行文件签名、symlink、响应大小、消息数和超时限制；
- App Server 恢复只读查询 thread/turn 元数据且不加载 items；启动、系统窗口事件和手动刷新可枚举现有窗口，只有用户明确点击后才会前置或最小化窗口；
- 动态计划不监听其他客户端的 App Server，也不轮询完整 thread items 或 transcript；它只由 VS Code Hook 在 `update_plan` 发生时推送，并用独立的同步 matcher 与本地高精度到达时间保证连续快照顺序；
- App Server 失败日志使用固定、无任务字段的消息，并以一分钟为最小间隔。

## Packaging boundary

`.build/` 和 `dist/` 只包含本机生成物，不属于源码发布面。`scripts/build-app` 生成 ad-hoc 签名的本机架构应用；正式二进制发布需要独立的 Developer ID 签名、公证、stapling、校验和与 provenance 流程。
