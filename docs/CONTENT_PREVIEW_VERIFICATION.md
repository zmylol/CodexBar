# 会话内容预览可行性验证

## 结论

现有本地 IPC 会话流可以为缩略图提供真实助手正文和工具完成结果，已有 Hook 可以继续负责生命周期和审批状态。无需为每种工具增加正文采集 Hook。

不能将这一结论扩大为“全部内容始终完整实时”：部分工具输出分片不广播，长历史可能分页，图片及其他附件需要独立验证。首次快照加连续 revision 的 patches 也不保证与 owner 当前全部状态相同。

## 验证环境与范围

| 项目 | 版本或范围 |
| --- | --- |
| macOS | 26.6，arm64 |
| 官方 VS Code | 1.136.1 |
| Codex IDE Extension | 26.901.22334 |
| 会话状态广播 | `thread-stream-state-changed` v11 |
| 订阅 | `thread-stream-following-changed` v1 |
| 测试对象 | 调用测试工具的当前 VS Code 会话，未枚举其他会话正文 |

临时探针验证 socket 所有者及权限，并按已知 conversation、host、owner 和目标客户端过滤广播。快照与正文仅在进程内存中处理，退出时取消订阅；报告仅保留结构、计数、匿名标记关联及比较结果。此探针阶段未修改产品源码和 Hook 配置。

## 真实传输结果

两次连接累计收到 5 份快照、86 批 patches，未观察到 revision 缺口。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 首次读取会话 | 通过 | 真实快照包含 `agentMessage`、`commandExecution` 等 item；正文和输出字段存在 |
| 新增助手正文 | 通过 | 测试标记从无到有经 patches 出现在 `agentMessage.text`，随后文字继续增长 |
| stdout 与 stderr | 通过 | 两个不同标记在同一个 `commandExecution.aggregatedOutput` 中出现 |
| 工具失败结果 | 通过 | 上述同一个命令 item 为 `failed`，`exitCode` 为预设值 7；该非零退出是测试设计 |
| 长工具完成输出 | 通过 | 25,025 字符的已知输出经 `aggregatedOutput` 收到，完整字符串逐字相等，状态为 `completed`，退出码 0 |
| 重新连接后恢复内容 | 通过 | 新连接首次快照仍包含此前的助手正文及两个已完成命令的测试内容 |
| 同 revision 的标记内容一致性 | 通过 | 重新快照中带标记 item 的完整输出字段、状态和退出码与内存增量结果一致 |
| 同 revision 的全部状态一致性 | 不通过 | 差异路径为 `turnHistory/history/entitiesByKey/*/items/*/aggregatedOutput` |
| 当前会话历史完整性标记 | 通过 | canonical history 为单 island，`isComplete` 和 `turnsPagination.hasLoadedOldest` 均为 true，未发现 item 分页缺口 |
| 完整历史加载入口 | 调用成功 | 定向 `thread-follower-load-complete-history` 请求成功；本会话在调用前已完整，因此未验证缺失分页的实际补齐 |

标记只在已确认的消息类型和输出字段内匹配；用户消息、工具参数和命令输入不作为输出证据。匿名 item 标签用于确认 stdout、stderr、终态和退出码来自同一次调用。

## 安装版本的源码证据

核对的代码来自上述扩展版本的 `out/extension.js` 和 `webview/assets/app-initial-*.js`，不是合成 router 测试。

- 快照传递 UI 会话状态；助手增量更新 `agentMessage.text`，正常广播 patches。
- `commandExecution/outputDelta` 更新内存输出时使用 `broadcastPatchesToFollowers: false`。运行中输出缓冲最多保留末尾 20,000 字符；`item/completed` 可以用上游最终 item 替换结果。本次 25,025 字符测试证明这一完成态结果未被该运行中缓冲上限截断，不能据此保证任意规模输出都不截断。
- `terminalInteraction` 和 `fileChange/patchUpdated` 也有不广播即时 patches 的路径。`item/mcpToolCall/progress` 未写入该会话正文，`item/fileChange/outputDelta` 不纳入内容状态。
- 再次发送 `following: true` 会补发快照。真实测试观察到相同 revision 下工具输出字段仍可能不同，因此不能仅凭 revision 相同跳过所请求的快照。
- canonical 历史经 `history.islands[].entries[].value` 关联 `history.entitiesByKey`，并需要合并实时 turn。turn 和 item 均有分页，不能把收到一个快照等同于已取得完整历史。
- 完整历史加载请求在带顶层 `hostId` 时使用 v2，定向当前 owner；参数为 `conversationId`。该 handler 读取历史、更新内存并广播，不启动新 turn。请求成功后仍需等待相应 revision 的状态并检查完整性字段。

## 实现建议与未验证项

最小方案是保留已有状态来源，给详情增加会话内容读取层：首次快照、正文增量、工具完成结果，以及打开预览或展开工具输出时的按需补快照。展示工具结果时使用实际收到的状态和退出码。

以下内容尚未完成真实场景验证：超长历史的多页补齐、MCP 与 dynamic tool 的各种输出、图片和其他附件、不同扩展版本、断线时正在产生的输出、任意规模输出的完整性。因此当前验证支持“会话正文与工具结果预览”，不支持“复制所有原始内部上下文”或“逐段镜像全部工具日志”的承诺。

## 首版实现验收

随后已将正文预览接入应用，并同步更新隐私说明：只在展开期间保留一个会话的内存正文，关闭或切换后释放，Hook 配置保持原样。

- 完整 `scripts/test` 通过，核心用例 265/265，包含新增 19 组正文 reducer 回归以及 3 组历史请求测试；Hook、模拟端到端、release bundle 和隔离安装/卸载检查通过。
- 原生滚动 harness 的 9 项场景通过，包括首次定位末尾、上滚暂停、新内容不抢位置、恢复跟随、窗口缩小、历史前插与尾部新增同时发生、展开和收起工具。组合前插场景已验证修改前失败、修复后通过。
- 真实会话预览已打开，确认历史用户消息、助手正文及命令/工具条目进入实际卡片；空摘要移除、命令标题补充可读名称。开发版已安装并启动，安装二进制与构建产物一致。
- Computer Use 在后续键盘操作中遇到窗口状态变化及屏幕捕捉错误；真实 PageUp、复制和 Escape 的完整交互验收仍需按人工清单执行，不能用滚动 harness 代替这些结果。重建后的本机应用提示需要重新授予 Accessibility 权限，VS Code 窗口跳转待恢复授权后验证。
