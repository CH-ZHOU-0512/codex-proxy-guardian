# Changelog

All notable changes are documented here. This project follows semantic versioning after the initial alpha series.

## [未发布 / Unreleased]

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
