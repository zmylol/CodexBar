# Codex IDE Hook 兼容性测试

自动化测试只能证明 CodexBar 能解析、脱敏和处理预期的 Hook JSON，不能证明任意版本的 Codex IDE Extension 一定会派发事件。每个发布版本都应在干净环境中完成以下人工验证。

## 测试边界

- 官方 Visual Studio Code Stable；
- 官方 OpenAI Codex IDE Extension；
- 两个目录名不同、内容不敏感的临时项目；
- 用户亲自在 Codex 设置中审核并信任 Hook；
- 不修改 `chatgpt.cliExecutable`，不使用跳过 Hook 信任的参数。

用户级 Hook 配置位于 `~/.codex/hooks.json`。CLI 与 IDE Extension 共用配置层，而当前 Hook 输入没有稳定的来源字段，因此本测试期间不要同时运行 Codex CLI 任务。

## 1. 安装 Probe

```sh
scripts/install-app
scripts/install-hooks --probe
```

Reload VS Code，在 Codex 侧栏进入 `Codex settings → Hooks`。必要时点击 `Reload hooks`，打开 `User config`，确认三条定义：

- 指向 `~/Library/Application Support/CodexBar/bin/codexbar-hook`；
- 参数包含 `--codexbar-managed --probe`；
- 事件分别为 `UserPromptSubmit`、`PermissionRequest` 和 `Stop`。

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
4. 检查 Probe 文件：

```sh
find "$HOME/Library/Application Support/CodexBar/Probe" -maxdepth 1 -name '*.json' -print
```

逐项确认：

- 两个项目的 `cwd` 不同且准确；
- `session_id` 能区分窗口；
- 同一 turn 的 `turn_id` 一致；
- 两个项目都出现 `UserPromptSubmit` 和 `Stop`；
- 授权场景出现 `PermissionRequest`；
- prompt 只有脱敏后的首行且不超过 80 个字符；
- `last_assistant_message` 只能是 `[REDACTED]`，不能出现正文。

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
