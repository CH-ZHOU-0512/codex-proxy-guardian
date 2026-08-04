# Changelog

All notable changes are documented here. This project follows semantic versioning after the initial alpha series.

## [未发布 / Unreleased]

## [1.4.5] - 2026-08-04

- 在 README 首页、Windows 设置界面、Status、Doctor、Issue 模板与 Wiki 中统一说明：Codex 的“正在重新连接”是流式连接重试，不等于 Guardian 重启了应用；应按同一时间是否存在 `codex_restart` / `proxy_changed` 事件进行归因。
- Status 与 Doctor 新增可分享的重连归因字段，列出 TLS EOF、WebSocket reset、Windows `10054` 与请求超时等常见上游信号，并明确代理服务商节点仍由用户的代理软件管理。
- 收紧首页与宣传图中的表达，只承诺减少“代理未继承或端点变化”造成的重连，避免把代理服务商节点自身的丢包或超时错误归因给 Guardian。

## [1.4.4] - 2026-08-04

- 修复 Settings 的“立即检查更新”把“另一个更新任务正在运行、本次并未检查”误报成“已经是最新版”的问题；结果现在明确显示本机版本、远端版本、通道、检查时间和 GitHub Release 来源，并按界面当前选中的通道实时检查。
- `chatgpt.com` 现在是 Windows 代理验证的关键目标，不能再由 API 与登录页的两个成功掩盖流式入口失败；状态与 Doctor 同时公开关键目标结果。
- 同一主机端口上的更高优先级协议可以在防抖后成为后续自然启动的首选，但协议变化仍不关闭当前 Codex；正在运行的 HTTP/SOCKS 进程按物理端点等价匹配，避免再次引入重启循环。
- 更新请求增加禁用缓存头，并返回 `Busy`、`NoEligibleRelease`、`Current`、`Available` 等可验证状态，减少模糊或过度乐观的界面提示。

## [1.4.3] - 2026-08-04

- 同一主机与端口上的 HTTP/SOCKS5 验证变化现在只视为传输协议替代，不再触发 Codex 生命周期操作；即使当前协议短暂验证失败、另一协议成功，也保持正在运行的 Codex 不动。
- Windows 所有可能关闭现有 Codex 的自动修复路径现在默认先显示前台确认框；只有用户明确点击“是”才会继续，点击“否”、超时或提示无法显示都会安全延后，默认 10 分钟后再询问。
- 状态新增 `RestartApprovalRequired`、`RestartDeferred`、`restartNotificationEnabled` 与 `restartDeferredUntilUtc`，重启调用增加不可绕过的审批参数，并补充协议生命周期与提醒决策回归测试。

## [1.4.2] - 2026-08-04

- 修复 Windows 自动发现同一个混合代理端口时，HTTP 与 SOCKS5 验证结果短暂波动会被误判为代理端点反复变化，进而连续重启 Codex 的严重问题。
- Guardian 现在会对同一主机与端口保留已经验证可用的协议；当前协议真实失效时仍可切换，代理主机或端口变化时仍会正常修复 Codex。
- 显式 `ProxyOverride` 与 `ExplicitProxy` 继续优先于协议粘滞，并新增同端点协议抖动、不同端点切换和显式配置覆盖回归测试。

## [1.4.1] - 2026-08-04

- Windows 安装器在启动 Guardian 后会核对 `status.json` 中的 PID 是否仍对应当前安装路径下的真实 Guardian，不再把过期的 `Stabilizing` 状态当作成功。
- Guardian 在安装健康验证期间意外退出时，安装器会清理过期状态并安全重试一次；第二次仍无法保持运行则明确失败并留下日志，不会向用户显示假的 100% 成功。

## [1.4.0] - 2026-08-04

- Windows 图形安装器由无限旋转改为 0–100% 确定进度条，同步显示解压、预检、连通性、文件复制、自启、更新任务和 Guardian 健康验证等当前阶段。
- EXE 按内嵌 ZIP 实际展开字节计算解压进度，`Install.ps1` 仅在安装器显式启用时通过私有协议回报已完成阶段；进度只前进不倒退，手动运行脚本不会输出内部标记。
- 增加 Windows PowerShell 5.1 安装预检协议回归测试，正式打包继续编译并自检单文件 EXE。

## [1.3.1] - 2026-08-04

- 修复 Windows PowerShell 5.1 将 GitHub Releases 顶层 JSON 数组保留为单个管道对象，导致更新器误报 `update_not_available` 的兼容问题。
- Release 选择器现在会安全展平该返回形态，更新脚本同时先接收 REST 结果再枚举，并增加 PowerShell 5.1 回归测试。

## [1.3.0] - 2026-08-04

- 新增三平台端到端 SOCKS5/SOCKS5H 支持：候选规范化、真实网络验证、Chromium 参数与 CLI 环境注入保持一致；常见代理程序的未知监听会同时尝试 HTTP 和 SOCKS5。
- Windows 使用当前用户 WinHTTP 自动代理解析器处理系统 PAC/WPAD；macOS/Linux 使用带下载大小、网络、DNS 和 JavaScript 执行时限的 PAC 运行时执行 `FindProxyForURL`。
- PAC 解析支持 `PROXY`、`HTTP`、`HTTPS`、`SOCKS`、`SOCKS5` 与 `DIRECT` 回退链；SOCKS4 继续安全拒绝。候选仍必须通过多目标真实请求门槛，目标路由不一致时保持不接管。
- 将系统已配置的远程代理与任意显式远程代理拆分为独立信任边界：前者由 `AllowSystemNonLoopbackProxy` 控制，后者仍需 `AllowNonLoopbackProxy` 明确授权。
- 新增真实 SOCKS5 转发测试、PAC JavaScript/超时测试、Windows WinHTTP PAC 集成测试、旧配置默认值迁移测试与四架构交叉编译验证。

## [1.2.0] - 2026-08-04

- 新增 macOS Intel / Apple Silicon 原生守护程序：发现并真实验证系统、环境变量和常见本地 HTTP/HTTPS 代理，通过当前用户 LaunchAgent 静默自启，并在端点稳定变化后受控修复 ChatGPT/Codex 桌面应用。
- 新增 Linux x64 / ARM64 原生守护程序与 `codex-guard`：通过 systemd user 或 XDG Autostart 自启，将已验证代理注入官方 Codex CLI，同时明确不强杀或自动重启交互式终端会话。
- macOS/Linux 默认每天检查稳定版 Release；更新前核对平台、架构、语义版本、文件名、包内 `VERSION`、SHA-256 和安全解包边界，原位替换失败时保留旧版本。
- 新增跨平台 Go 核心、单实例、防抖、重启冷却/熔断、JSONL 日志轮转、脱敏 Doctor、当前用户安装与安全卸载脚本。
- Release 现在同时生成 Windows EXE/ZIP，以及 macOS/Linux 四种 `.tar.gz` 与各自 SHA-256；CI 在 Windows、macOS、Linux 上运行原生单测和编译检查。
- 补充跨平台安装、支持矩阵、架构、故障排查和平台限制说明。Linux 当前对应官方 Codex CLI，不虚构官方 Linux 桌面端支持。

## [1.1.0] - 2026-08-03

- 新增面向普通用户的单文件图形化安装器 `CodexProxyGuardian-Setup-1.1.0.exe`，双击即可完成当前用户安装或原位升级。
- EXE 内嵌与 Release ZIP 完全相同的载荷；构建时会校验内嵌版本、必需文件、安全解压边界和安装器自检结果。
- 安装器不申请管理员权限、不直接修改网络配置，使用系统自带 Windows PowerShell 调用经过测试的 `Install.ps1`，并限制最长执行时间。
- GitHub Release 同时发布 EXE、ZIP 及各自的 SHA-256 文件；ZIP 手动安装和 Guardian 现有自动更新机制继续兼容。
- 更新中英文 README、支持矩阵、Release 说明和自动化测试，明确未签名 EXE 的 SmartScreen 提示与校验方式。

## [1.0.0] - 2026-08-03

- 首个正式版本；新安装默认跟随 Stable 更新通道，已有安装继续保留用户选择。
- 增加开始菜单设置窗口，将技术模式显示为“自动（Safe）”和“严格（Enforce）”，无需手改 JSON。
- `Control.ps1` 增加 `SetMode`、`ToggleMode`、`Configure`、`CheckUpdate` 和 `Update` 操作；模式切换由 Guardian 后台热加载，不重启 Guardian 或 Codex。
- 增加每日当前用户自动更新任务；更新器固定到本项目 GitHub Release，并核对通道、语义版本、资产名称、包内 `VERSION` 和 SHA-256。
- 自动更新增加安装前快照、失败回滚、GitHub 资产摘要核对与安全解压限制，并写入独立更新日志；设置窗口可关闭自动更新或选择 Stable/Prerelease 通道。
- 状态与 Doctor 报告增加用户模式、自动更新配置、任务状态和最近运行结果。

## [0.3.1-alpha] - 2026-08-03

- 修复旧 Guardian 异常退出且 PID 被其他程序复用时，安装器为避免误杀而拒绝升级的问题。
- 安装器现在按完整 watcher 路径识别实际 Guardian；过期 PID 只产生警告，绝不终止占用该 PID 的无关进程。

## [0.3.0-alpha] - 2026-08-03

- Safe 模式增加证据驱动的普通 Codex 启动修复：先等待代理流量，确认未生效后才受控重启一次。
- Enforce 模式继续严格校正缺少当前代理参数的 Codex，同时沿用防抖、冷却、频率限制与熔断。
- 改进多应用 MSIX 清单解析，根据显式应用 ID、已知可执行文件名和完整路径选择 Codex 根进程。
- Store 更新期间如果暂时无法解析替代可执行文件，保留仍在运行的 Codex，不执行先关闭后失败的重启。
- 状态与 Doctor 报告增加外部启动策略、解析方式、应用 ID、架构和可执行文件名，便于兼容性反馈。
- 安装说明增加“安装后怎么使用”，明确普通启动、Managed Proxy 快捷方式以及 Safe/Enforce 的区别。
- 将简体中文设为默认 README 和主要用户入口，同时保留独立英文说明。
- 增加中文仓库简介、Release 说明、Issue/PR 模板、兼容性矩阵、故障排查、安全策略和贡献指南。
- Added Chinese-first repository discovery and support content while retaining dedicated English documentation.
- 增加可复现的 GitHub 分享封面和 README 工作流程图。

## [0.2.0-alpha] - 2026-08-02

- Added a restart-rate circuit breaker so an unstable environment cannot keep relaunching Codex indefinitely.
- Added persisted relaunch recovery so a failed managed start is retried without creating an unlimited restart loop.
- Added deterministic candidate ordering with active-endpoint hysteresis and inherited proxy-environment discovery.
- Added multi-target OpenAI/ChatGPT HTTPS validation with configurable quorum and richer effectiveness evidence.
- Added periodic MSIX manifest re-resolution so Codex Store updates do not leave a stale executable path.
- Added recent Codex-to-proxy TCP connection evidence, lifecycle states, read-only Doctor diagnostics, and safer configuration migration.
- Broadened process and common-port discovery for current Clash/Mihomo, v2rayN/Xray, sing-box, Hiddify, Neko, and related Windows clients.

## [0.1.0-alpha] - 2026-08-02

- Initial open-source alpha.
- Added explicit/system/process-listener proxy discovery with TCP and HTTPS validation.
- Added stable-sample debounce, restart cooldown, exponential retry, rotating JSONL logs, and per-install single-instance mutex.
- Added MSIX manifest-based Codex executable discovery for x64 and ARM64.
- Added Safe default and opt-in Enforce mode.
- Added path-bound installation markers, current-user startup, silent launch, status, and guarded uninstall.
- Added static/unit tests, Windows PowerShell/PowerShell CI, release ZIP generation, checksum, documentation, and security policy.
