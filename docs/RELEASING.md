# 本地构建与正式分发

`scripts/build-app` 和 `scripts/install-app` 仍用于个人从源码构建、安装。它们使用 ad-hoc 签名，不代表 Developer ID 分发包，也不会提交公证。更新源构建后，辅助功能权限可能需要重新授予。

正式分发使用 `scripts/release-app`，需要 Python 3.9+、macOS 开发工具、包含私钥的 Developer ID Application 证书，以及真实兼容性验证记录。没有证书或真实记录时，流程明确失败；仓库中的示例与自动化 stub 测试不能证明某个真实 VS Code/扩展版本兼容。

## 安装已发布的二进制包

下载最终 `CodexBar.zip`，核对发布页提供的 SHA-256，解压后把 `CodexBar.app` 放到 `/Applications` 或 `~/Applications` 的直属位置，再打开应用。只使用知识库阅读功能时，不需要任务连接。

要显示 VS Code Codex 任务，在应用菜单点击“安装或更新任务连接…”。这个明确操作会打开 Terminal，运行应用内的 `HookSetup/Install.command`，调用打包的现有安全安装器，把 Hook 命令指向**当前已安装应用**内的 `Contents/Helpers/codexbar-hook`，保留第三方 Hooks，并备份被修改的本地 Hook 配置。无需下载源码、安装 Swift 或另找 `scripts/install-hooks`。

安装结束后，重新加载 VS Code，在 **Codex Settings > Hooks** 手动检查并信任定义。安装器不会自动修改信任状态。更新应用后可以再次点击同一菜单更新任务连接；如果移动了应用，也需要重新执行。入口拒绝从 Downloads、构建用 dist、App Translocation 或 Applications 子目录配置连接，避免 Hook 指向临时路径。`CODEXBAR_APPLICATIONS_ROOT` 仅供隔离测试配置安装根目录。

包内 `Contents/Resources/HookSetup` 包含 `Install.command`、`install-hooks`、`hook-config-common.zsh` 和 `hooks-config.js`，随应用资源一起被签名覆盖。命令仅由用户点击启动，应用不会后台执行配置安装。

## 1. 验证当前源码的真实兼容性

先运行 `scripts/test`、`scripts/test-app-bundle` 和 `scripts/test-release-app`。分发脚本不代替这些检查，也不自动修改 Hooks、辅助功能权限或用户配置。

从 [记录示例](compatibility-record.example.json) 复制自己的记录到工作目录。示例中的版本号只是格式示范，全部场景初始为 `not_run`，`evidence_kind` 为 `synthetic`，无法通过发布门槛。请不要把示例改成 `real` 来绕过测试。

运行以下命令，保存待测源码的指纹：

```sh
scripts/release-app --source-fingerprint
```

指纹包含 `Package.swift`、`Sources/`、`Resources/`、`scripts/build-app`、`scripts/install-app`、`scripts/release-app` 及实际打包的 `scripts/install-hooks`、`scripts/hook-config-common.zsh`、`scripts/hooks-config.js` 的路径、权限及文件内容。测试完成后再次运行，确认指纹未变化，再填入记录的 `source_sha256`。使用内容指纹而非 Git HEAD，避免提交验证记录本身使记录失效。

在真实 macOS 图形会话中，运行当前源码构建的应用，使用官方 VS Code Stable 和实际安装的 Codex 扩展，逐项验证：

| 场景字段 | 通过条件 |
| --- | --- |
| `app_launch` | 应用能启动；首次使用和升级后均能完成必要权限操作 |
| `hook_task_lifecycle` | 真实 Codex 任务经 Hooks 进入运行状态，完成后状态正确 |
| `approval_required` | 真实需要批准的操作显示等待批准 |
| `approval_resume` | 允许操作后立即恢复运行状态，不继续挂在等待批准 |
| `window_focus` | 点击任务能定位对应 VS Code 窗口；多窗口不混淆 |
| `conversation_preview` | 助手正文持续更新；核对工具完成态输出，未广播的运行中输出可在展开刷新或完成后补齐 |
| `reconnect_same_socket` | 在测试环境中断连接但保留服务及同一 socket，状态和会话订阅自动恢复；反复仅握手后断线应耗尽重试 |
| `history_loading` | 加载较早历史后，旧记录可读，新消息和状态继续更新 |
| `knowledge_arrival` | 在测试知识库写入有效今日文章，列表与未查看提醒更新，查看后不重复提醒 |

记录 `tester`、带时区的 `tested_at`，为每个环境填写实际 `macos`、`architecture`、`vscode`、`codex_extension` 版本及 `vscode_channel: stable`。`evidence` 记下各项观察和本地验证日志的位置；不要放入凭据、真实会话正文或私人笔记。只有全部场景通过后，才将该记录的 `evidence_kind` 设为 `real`，对应场景设为 `pass`。

脚本验证声明的完整性、当前源码指纹与实际产物架构，不能独立证明人工声明属实。发布者负责留存真实观察。构建只生成本机架构：arm64 的记录不意味着 x86_64 已验证；分发某个架构的包前必须有该架构的真实记录。未覆盖的 macOS/VS Code/扩展版本应标明未验证。

## 2. 检查证书并准备候选包

通过 Apple Developer 账户创建 Developer ID Application 证书并安装到自己的 Keychain；不要把证书私钥或公证密码放进仓库。使用完整且唯一的证书名称：

```sh
scripts/release-app --check \
  --identity 'Developer ID Application: Your Name (TEAMID1234)' \
  --compatibility /absolute/path/compatibility.json

scripts/release-app --prepare \
  --identity 'Developer ID Application: Your Name (TEAMID1234)' \
  --compatibility /absolute/path/compatibility.json \
  --output dist/release-0.1.0-arm64
```

`--check` 只做本地门槛检查。`--prepare` 执行 release 构建，复制应用到暂存目录，先签 `codexbar-hook`，再签外层 `.app`；两者启用 hardened runtime 和 secure timestamp，并验证签名、Team ID 和架构。签名时不使用 `--deep`，验证时使用。Apple 建议为每个代码组件按由内到外顺序签名，并为 Developer ID 添加 runtime 和 timestamp。[Apple 签名说明](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)

准备阶段可能联系 Apple 的时间戳服务，但不会上传应用公证。输出目录必须不存在，避免覆盖已审查的候选。成功后包含：

- `CodexBar.app`：签名候选，尚未公证。
- `compatibility.json`：此次候选采用的实测记录。
- `manifest.json`：源码与应用指纹、签名身份、版本、构建号和实际架构，状态为 `prepared`。

审查这些产物后再执行下一阶段。`prepared` 不表示可公开分发；没有有效 Developer ID 私钥时，此阶段停止，不能退回 ad-hoc 签名冒充正式包。

## 3. 显式提交公证并生成最终 ZIP

先按 Apple 的 `notarytool store-credentials` 流程将凭据保存为 Keychain profile。脚本只接收已有 profile 名称，不接收或保存明文密码。公证使用 `notarytool`，并等待 Apple 返回结果。[Apple 公证工作流](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

**下列命令会把候选应用上传给 Apple，并下载公证票据：**

```sh
scripts/release-app --notarize \
  --output dist/release-0.1.0-arm64 \
  --keychain-profile CodexBar-notary
```

脚本重新核对当前源码、兼容性记录、候选应用指纹及签名，再复制到工作目录并上传 ZIP。只有 Apple 返回 `Accepted` 后，才执行 `stapler staple`、`stapler validate`、签名复查和 `spctl` Gatekeeper 检查。全部通过后重新打包**已经 stapled 的应用**，生成最终 ZIP 及其 SHA-256。Apple 推荐 ZIP 使用 `ditto -c -k --keepParent`；ZIP 本身不能签名，离线启动需给包内应用附加票据。[Apple 打包说明](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

成功时新增 `CodexBar.zip`、`SHA256SUMS`、`notarization.json`，`manifest.json` 的状态变为 `ready` 并记录公证提交 ID 和 ZIP 校验和。外层保留的原始 `CodexBar.app` 用于审计，仍是准备阶段的候选；**交付物是最终 `CodexBar.zip`**，其中才包含 stapled 应用。

验证校验和：

```sh
cd dist/release-0.1.0-arm64
shasum -a 256 -c SHA256SUMS
```

如果公证拒绝，检查 `notarization.json` 并按其中 ID 获取 Apple 的公证日志。缺失凭据、未接受、stapling 或 Gatekeeper 失败，都不会生成正式 ZIP。提交可能需要较长时间；中断或网络故障时，先在 Apple 查询已有提交状态，避免反复提交。原候选保持不变，可在问题处理后重试；源码变更则需要重新验证兼容性并准备新候选。

正式上传到发布站点前，还应在真实、干净的用户环境解压最终 ZIP，验证首次启动和升级。`ready` 表示自动分发检查通过，不代替最终包的人工使用检查。脚本不会创建 GitHub Release、推送 tag 或上传公开站点；这一步由维护者另行执行。

## 回归测试的边界

`scripts/test-release-app` 在临时目录建立小型源码副本和 Apple 工具 stub，验证门槛、签名顺序、禁止隐式公证、失败后不出正式包、stapling 后重新打包，以及最终 ZIP 校验和。它不访问真实 Keychain、用户 Hooks 或网络，其通过结果只能证明脚本控制流程，不能声称完成真实 Developer ID 签名、公证或产品兼容性测试。

`scripts/test-hook-setup` 把真实 Hook 安装器复制到临时应用目录，验证安装位置限制、包含空格和单引号的路径、当前 bundle 的 helper、重复安装、第三方配置保留、畸形配置与符号链接拒绝。所有配置路径均指向临时目录，信任配置保持原样。
