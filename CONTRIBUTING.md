# Contributing to CodexBar

感谢你改进 CodexBar。提交代码即表示你同意按照本仓库的许可证贡献这些修改。

## 开发环境

- macOS 13 或更高版本；
- Swift 6.0 或更高版本；
- Xcode Command Line Tools；
- 官方 Visual Studio Code Stable（仅人工窗口测试需要）；
- 官方 OpenAI Codex IDE Extension（仅真实 Hook 测试需要）。

克隆仓库后运行：

```sh
scripts/test
```

这是项目的权威测试入口，包含 Swift 核心测试、应用 Model/Store 检查、Hook 配置测试、模拟端到端流程、release 构建、应用 bundle 和隔离安装测试。核心套件采用不依赖 XCTest 的 `codexbar-tests` 可执行目标，以兼容只安装 Xcode Command Line Tools 的开发环境；不要用 `swift test` 代替。测试必须使用临时目录，不得修改开发者真实的 `~/.codex/hooks.json`、`~/Applications` 或 Application Support 数据。

`scripts/test-app-models` 可单独运行预览状态、知识库审核和知识库模型检查，已由上述入口纳入 CI。它不需要图形桌面，但知识库模型检查需要访问 macOS 文件事件服务。`scripts/test-preview-performance` 还会运行滚动、SwiftUI 界面、原生交互和目录选择器检查，需在已登录的 macOS 图形桌面中执行；修改这些界面或准备发布时应运行该入口。

## 修改原则

- 先提交能复现问题的测试，再实现最小修复；
- 不读取或保存完整 Codex transcript；
- 新增持久化字段前，必须同步更新 `PRIVACY.md`；
- 涉及 Hook 安装或卸载时，必须保留未知的第三方 Hook；
- 涉及 Accessibility 时，操作范围必须限制在官方 VS Code 窗口；
- 不提交 `.build/`、`dist/`、本机路径、真实 session/turn ID、prompt 或项目名称。

## Pull Request

PR 应说明：

1. 用户可见的问题或目标；
2. 采用的最小实现；
3. 测试命令和结果；
4. 是否改变权限、持久化数据、Hook 配置或发布流程。

真实 IDE/Accessibility 验证请使用中性项目名，并只记录版本组合与通过/失败结论。不要上传完整 Probe 文件。
