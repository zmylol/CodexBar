# Security Policy

## Supported versions

安全修复只面向 `main` 分支和最新发布版本。这个项目目前处于早期阶段，尚不承诺长期维护旧版本。

## Reporting a vulnerability

请优先使用 GitHub 仓库的 **Security → Report a vulnerability** 私密报告入口。不要在公开 Issue 中粘贴漏洞细节、Hook 配置、session/turn ID、prompt、绝对路径或其他本机数据。

如果私密报告入口尚未启用，请只创建一个不含技术细节的 Issue，请求维护者提供私密沟通渠道。

报告中可以包含：

- 受影响的 commit 或版本；
- 最小复现步骤；
- 实际影响和必要前提；
- 已脱敏的日志或测试；
- 建议的修复方向。

## Security boundary

CodexBar 是当前用户权限下运行的本地工具，不提供权限隔离或沙箱边界。主要安全边界包括：

- 用户级 `~/.codex/hooks.json`；
- `~/Library/Application Support/CodexBar/` 中的私有事件数据；
- macOS Accessibility 权限；
- 官方 VS Code 进程与 VS Code Extension 内 Codex 可执行文件的身份；
- CodexBar 启动的本地 `codex app-server` 子进程。

CodexBar 不应被用于运行来源不明的 Hook 可执行文件，也不应通过跳过信任检查的参数启用 Hook。

Hook 入口只接受 VS Code Extension 提供的精确 originator 值；缺失、变体或其他客户端来源全部 fail-closed 且不读取 stdin。窗口操作只接受 `com.microsoft.VSCode` 且代码签名满足 Microsoft Team ID `UBF8T346G9` 的实时进程；发现和执行前均采用 fail-closed 验证。Codex App Server 只从官方 Extension 路径选择 OpenAI Team ID `2DC432GLL2` 的可执行文件，并在启动前二次验证，查询和响应来源都必须为 `vscode`。

安装、卸载和运行时存储会拒绝 CodexBar 管理路径中的符号链接；任务状态持久化失败时，Inbox 事件不会被提前归档。
