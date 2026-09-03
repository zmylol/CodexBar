# CodexBar

CodexBar 是一个常驻桌面的 macOS 原生悬浮条，用来汇总多个 Visual Studio Code 窗口中的 Codex 任务状态。悬浮条默认只显示项目名；鼠标悬停或键盘聚焦时才显示任务摘要、状态和时间。

点击项目后，CodexBar 只会尝试恢复并前置已经存在且唯一匹配的官方 VS Code 窗口，同时最小化其他标准 VS Code 窗口。它不会执行 `code -r`，也不会创建新窗口。

> CodexBar 是独立的社区工具，与 OpenAI 或 Microsoft 没有隶属或背书关系。Codex、OpenAI、Visual Studio Code 及相关标识归各自权利人所有。

## 当前状态

仓库提供可从源码构建的早期版本，尚未提供 Developer ID 签名或 Apple 公证的正式二进制。`scripts/build-app` 生成的应用使用 ad-hoc 签名，仅适合本地开发和测试。

## 功能

- 将 `UserPromptSubmit`、`PermissionRequest`、`Stop` 映射为“执行中”“需要处理”“可查看”；
- 通过官方 Codex Hooks 在应用未运行时继续接收事件；
- 启动时恢复已打开窗口中的历史任务，并对现有 VS Code 或终端 CLI 活跃任务通过官方 Codex App Server 补偿缺失的终止事件；
- 验证 VS Code 的 bundle id 与 Microsoft Team 签名，并只在窗口候选唯一时执行前置和最小化；
- 紧凑悬浮条只显示项目名，悬停时显示详细信息；
- 本地事件使用私有目录和文件权限，并自动轮转原始事件归档；
- 不包含第三方 Swift Package 依赖。

## 支持范围

- macOS 13 或更高版本；
- 官方 Visual Studio Code Stable（bundle id `com.microsoft.VSCode`）；
- 官方 OpenAI Codex IDE Extension；
- 本地 Codex turn；
- 每个 VS Code 窗口对应一个主要项目，项目目录名基本唯一。

暂不支持 Codex App、Cursor、Windsurf、VS Code Insiders、Windows、Linux、多 thread 精确定位或 multi-root workspace。Codex CLI 与 IDE 共用用户级 Hook 配置，而 Hook 事件目前没有稳定的来源字段；终端 CLI 事件可以进入 CodexBar，并可通过精确 session/turn 核对收口状态，但点击项目仍只负责切换已存在的 VS Code 窗口。

## 工作方式

| Codex Hook | 内部状态 | 界面文案 |
| --- | --- | --- |
| `UserPromptSubmit` | `running` | 执行中 |
| `PermissionRequest` | `needsAttention` | 需要处理 |
| `Stop` | `ready` | 可查看 |

`Stop` 只表示当前 turn 已停止，因此界面不会写“已完成”。Hook 保存 session/turn 标识、cwd、脱敏后的 prompt 首行、事件类型、工具名称和时间；不会保存完整 assistant message 或 transcript。详细字段、保留期限和删除方式见 [PRIVACY.md](PRIVACY.md)。

启动恢复会通过官方 Extension 内置的 [Codex App Server](https://learn.chatgpt.com/docs/app-server) 查询来源为 `vscode` 的持久线程，并根据现有窗口保守恢复历史行。手动中断 turn 时，Codex 可能不派发 `Stop`；因此存在“执行中”或“需要处理”的行时，CodexBar 还会每五秒至多发起一次单飞查询，按已有任务的 session ID、turn ID 和 cwd 精确核对 `vscode` 与 `cli` thread，并将同一 turn 的 `completed`、`interrupted` 或 `failed` 状态映射为“可查看”。周期查询不依赖 VS Code 窗口，只允许更新查询开始时已经存在的活跃行，不会恢复用户已删除的行或覆盖更新的 Hook turn。

CodexBar 只持久化启动时唯一匹配到现有窗口、或周期核对时精确匹配到已有任务的必要元数据；查询失败、超时或可执行文件签名不属于官方 OpenAI Team 时，会回退到 Hook 和本地任务存储，并向 macOS 统一日志写入不含任务字段的限频诊断。

## 从源码安装

需要 Swift 6.0 或更高版本以及 Xcode Command Line Tools。

```sh
scripts/test
scripts/install-app
```

应用安装到：

```text
~/Applications/CodexBar.app
```

Hook 可执行文件安装到：

```text
~/Library/Application Support/CodexBar/bin/codexbar-hook
```

### 1. Probe 验证

先使用不影响正式任务列表的 Probe 模式验证当前 IDE Extension 是否真实派发 Hook：

```sh
scripts/install-hooks --probe
```

安装器会解析并备份现有 `~/.codex/hooks.json`，使用锁、文件指纹和原子替换合并三条 CodexBar handler。它只迁移或删除可执行路径精确匹配的 CodexBar handler，不会根据参数名称猜测第三方 Hook 的归属。

Reload VS Code，然后在 Codex 侧栏进入 `Codex settings → Hooks`。必要时点击 `Reload hooks`，打开 `User config`，核对三条命令的绝对路径与 `--probe` 参数，再由你点击 Trust。

IDE 聊天框里的 `/hooks` 不是可用命令。官方 [Hooks 文档](https://learn.chatgpt.com/docs/hooks)描述的 `/hooks` 是 CLI 审核入口；不要使用跳过 Hook 信任的参数，也不要修改 `chatgpt.cliExecutable`。

按 [Hook 兼容性测试](docs/HOOK_COMPATIBILITY.md)确认两个窗口均收到真实事件后，切换正式模式：

```sh
scripts/install-hooks
```

Probe 与正式 Inbox 的定义哈希不同，因此切换后需要重新 Reload hooks、审核定义并 Reload VS Code 窗口。

### 2. 启动与辅助功能权限

```sh
open "$HOME/Applications/CodexBar.app"
```

没有 Accessibility 权限时，悬浮条仍能显示任务。点击项目需要前往：

```text
System Settings → Privacy & Security → Accessibility → CodexBar
```

权限用于枚举、匹配、恢复、前置和最小化通过 Microsoft Team 签名验证的官方 VS Code 窗口。进程会在发现时和执行窗口操作前再次验证。CodexBar 不安装全局键盘监听，不记录其他应用的键盘输入。

ad-hoc 签名会在重新构建后改变代码身份，macOS 可能要求重新添加 Accessibility 权限。稳定复用授权需要维护者使用固定 Developer ID 签名并完成公证。

## 模拟任务状态

将路径换成已经在独立 VS Code 窗口打开的真实绝对路径：

```sh
scripts/send-test-event running /path/to/project-alpha "Refactor authentication hooks"
scripts/send-test-event attention /path/to/project-alpha
scripts/send-test-event ready /path/to/project-alpha
```

依次应看到“执行中”“需要处理”“可查看”。模拟事件只能验证本地链路，不能证明 IDE Extension 会真实触发 Hook。

## 卸载

默认卸载应用和 CodexBar 管理的 Hook，但保留本地任务、事件和备份：

```sh
scripts/uninstall-app
```

明确需要同时删除 Application Support 数据时：

```sh
scripts/uninstall-app --purge-data
```

该操作不可恢复。窗口位置偏好和系统 Accessibility 授权由 macOS 分别管理；需要时可另外执行：

```sh
defaults delete com.codexbar.CodexBar
tccutil reset Accessibility com.codexbar.CodexBar
```

如果只想移除 Hook，或者恢复安装前的完整 Hook 配置：

```sh
scripts/uninstall-hooks
scripts/restore-hooks --force
```

`restore-hooks --force` 会覆盖当前配置，执行前仍会再做备份。

## 开发与测试

```sh
scripts/test
```

完整入口会运行 Swift 核心测试、Hook CLI 与配置隔离测试、三状态模拟、运行中应用的模拟端到端流程、release 构建、应用 bundle 和隔离安装/卸载测试。核心套件是兼容独立 Xcode Command Line Tools 的 `codexbar-tests` 可执行目标，因此请使用 `scripts/test`，不要用 `swift test` 代替。贡献说明见 [CONTRIBUTING.md](CONTRIBUTING.md)，安全问题请按 [SECURITY.md](SECURITY.md) 私密报告。

## 已知限制

- App Server 不提供 VS Code 窗口到当前 thread 的精确映射；只有启动历史恢复会根据 cwd 和窗口标题保守推断，现有活跃任务使用精确 session/turn 核对。
- 启动扫描超过 500 条未归档 VS Code 历史时会放弃该次恢复，避免基于不完整结果猜测。
- App Server 无法恢复一个仍在等待中的 `PermissionRequest`；`inProgress` 快照不会覆盖已有 Hook 的“需要处理”，但同一 turn 的终态会将其收口为“可查看”。
- `PermissionRequest` 没有单独的“已处理”事件，状态可能保持到同一 turn 的 `Stop`、新 prompt，或下一次成功的 App Server 终态核对。
- 同名项目、multi-root 或同一项目多窗口会被视为歧义并拒绝切换。
- CodexBar 不定位具体 Codex thread，只保留目标 VS Code 窗口原本打开的页面。
- Hook 输入上限为 4 MiB；超限时静默 fail-open，避免阻塞 Codex。
- prompt 摘要脱敏是降低意外暴露的保护层，不是秘密扫描器；不要在 prompt 中粘贴凭证。
- 当前构建脚本只生成本机架构的 ad-hoc 应用，不是正式 Release 流程。

## License

[MIT](LICENSE)
