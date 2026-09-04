# Codex IDE Hook 兼容性测试

自动化测试只能证明 CodexBar 能解析、脱敏和处理预期的 Hook JSON，不能证明任意版本的 Codex IDE Extension 一定会派发事件。每个发布版本都应在干净环境中完成以下人工验证。

## 测试边界

- 官方 Visual Studio Code Stable；
- 官方 OpenAI Codex IDE Extension；
- 两个目录名不同、内容不敏感的临时项目；
- 用户亲自在 Codex 设置中审核并信任 Hook；
- 不修改 `chatgpt.cliExecutable`，不使用跳过 Hook 信任的参数。

用户级 Hook 配置位于 `~/.codex/hooks.json`，会被多个 Codex 客户端看到。CodexBar 只接受 VS Code Extension 提供的精确 `codex_vscode` originator；CLI、其他客户端、缺失值和任何变体都会静默忽略。因此在其他客户端运行任务不应生成 CodexBar 事件。

## 1. 安装 Probe

```sh
scripts/install-app
scripts/install-hooks --probe
```

Reload VS Code，在 Codex 侧栏进入 `Codex settings → Hooks`。必要时点击 `Reload hooks`，打开 `User config`，确认五个 handler（覆盖四种事件）：

- 指向 `~/Library/Application Support/CodexBar/bin/codexbar-hook`；
- 参数包含 `--codexbar-managed --probe`；
- 事件分别为 `UserPromptSubmit`、`PreToolUse`、`PermissionRequest` 和 `Stop`；
- shell、读、搜和编辑的 `PreToolUse` handler 异步执行；`update_plan` 单独使用同步 handler，以保持连续计划快照的顺序；其他三个生命周期 handler 也保持同步。
- 两个 `PreToolUse` matcher 互斥且只覆盖上述普通动作与精确的 `update_plan`，不捕捉其他本地工具或 MCP 调用。

核对后由测试者点击 Trust。CodexBar 不会自动代替用户审核 Hook。

如果 IDE Extension 没有 Hooks 设置页，先更新 Extension。官方 [Hooks 文档](https://learn.chatgpt.com/docs/hooks)提供的 `/hooks` 是 CLI 审核入口，不是 IDE 聊天命令。

## 2. 双窗口验证

分别在两个 VS Code 窗口打开中性测试目录：

```text
VS Code A → project-alpha
VS Code B → project-beta
```

1. 在 A 提交短任务并等待 turn 停止。
2. 在 B 提交不同任务并等待 turn 停止。
3. 在其中一个 turn 请求一项安全、可拒绝且明确需要授权的操作；看到授权框后拒绝。
4. 让其中一个 turn 至少执行一次文件读取、编辑或测试命令，并运行一次带多个步骤的 `update_plan`。
5. 检查 Probe 文件：

```sh
find "$HOME/Library/Application Support/CodexBar/Probe" -maxdepth 1 -name '*.json' -print
```

逐项确认：

- 两个项目的 `cwd` 不同且准确；
- `session_id` 能区分窗口；
- 同一 turn 的 `turn_id` 一致；
- 两个项目都出现 `UserPromptSubmit` 和 `Stop`；
- 工具动作出现 `PreToolUse`，只包含受限的动作分类和安全路径摘要；
- 计划更新出现 `toolName: update_plan`；Probe 不保留计划正文，正式模式只把脱敏后的计划短暂传给内存缩略图；
- 授权场景出现 `PermissionRequest`；
- prompt 只有脱敏后的首行且不超过 80 个字符；
- `last_assistant_message` 只能是 `[REDACTED]`，不能出现正文。

同时确认 Probe 中没有原始命令、补丁正文、搜索词、计划正文、MCP 参数或工具输出。

不要把 Probe 文件、完整 ID、绝对 cwd 或 prompt 提交到仓库。

## 3. 切换正式 Inbox

只有上述项目全部通过后才运行：

```sh
scripts/install-hooks
```

定义哈希会改变。回到 `Codex settings → Hooks`，Reload hooks、重新审核并 Reload 两个 VS Code 窗口，然后按 [MANUAL_TEST.md](MANUAL_TEST.md) 完成正式验收。

## 发布记录模板

发布说明只记录必要的兼容性信息：

| CodexBar | macOS | VS Code | Codex Extension | 架构 | 结果 |
| --- | --- | --- | --- | --- | --- |
| release tag/commit | major.minor | version | version | arm64/x86_64 | pass/fail |

不要记录用户名、机器名、项目名、精确测试时刻、session/turn ID 或 prompt。
