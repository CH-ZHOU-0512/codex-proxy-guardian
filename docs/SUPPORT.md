# 兼容性与支持矩阵

[简体中文](SUPPORT.md) | [English](SUPPORT.en.md)

## 已验证的设计基线

| 平台 | 架构 | Codex 对象 | 系统代理来源 | 当前用户自启 |
|---|---|---|---|---|
| Windows 11 | x64、ARM64 | Store / Store 签名 MSIX 桌面端 | Internet Settings `ProxyServer` | 计划任务，失败时 HKCU Run |
| macOS | Intel、Apple Silicon | ChatGPT/Codex 桌面应用 | `scutil --proxy` | LaunchAgent |
| Linux | x64、ARM64 | 官方 Codex CLI | GNOME `gsettings` | systemd user，失败时 XDG Autostart |

所有平台都要求当前用户会话和带明确端口的 HTTP/HTTPS 代理；支持显式配置、继承的 `HTTPS_PROXY` / `HTTP_PROXY` / HTTP 兼容 `ALL_PROXY`，以及已识别代理进程拥有的回环监听器。候选端点必须通过 TCP 和经代理 HTTP(S) 请求成功数门槛。

Windows 使用 PowerShell 核心和图形安装器；macOS/Linux 使用静态 Go 二进制与 POSIX 安装脚本。三者共享相同的安全原则，但不是同一套进程控制实现。

## 暂不自动支持

- PAC 文件、WPAD 或自动配置脚本。正确解析 PAC 需要针对每个目标执行受系统策略影响的 JavaScript。
- 纯 SOCKS4/SOCKS5 端点。当前版本有意只接受 HTTP/HTTPS 代理语义。
- 没有 HTTP 或混合入站端口的纯 TUN 模式。
- 仅设置 WinHTTP 代理的环境。Codex 是桌面应用，读取 WinHTTP 会产生不明确的优先级。
- 位于其他用户或服务会话中，且无法安全归属于当前桌面配置的代理监听器。
- URL 中嵌入认证信息的代理。为避免凭据出现在命令行、进程列表或日志中，此类地址会被拒绝。
- 要求脚本签名或强制使用 Constrained Language Mode 的企业组策略环境。
- 非 MSIX 或第三方改名的 Codex 包，除非配置了精确包名且清单提供可直接启动的可执行文件。
- Linux Codex 桌面端。OpenAI 当前没有发布官方 Linux 桌面应用；Linux 版只为官方 Codex CLI 提供 `codex-guard`。
- 对已经启动的 Linux 终端进程“补写”环境变量，或自动结束/重启交互式 Codex CLI。进程环境无法从外部安全改写。
- macOS 上安装到自定义路径但未加入 `MacApplicationPaths` 的桌面应用。

## 提交兼容性报告

提交 Issue 前，请优先生成专门设计的脱敏诊断报告：

macOS/Linux：

```sh
codex-proxy-guardian doctor
```

Windows：

```powershell
.\Doctor.ps1 -Online -Json -ExportPath .\codex-proxy-guardian-diagnostics.json
```

同时说明代理软件名称与版本，以及它使用系统代理、HTTP/混合端口还是 TUN 模式。只有产品名称不足以判断实际路由行为。

`Status.ps1 -Json`、`config.json` 和 JSONL 日志属于本机运行数据，**不能视为可直接公开分享的安全内容**。只有维护者明确请求特定字段或事件时才应提交，并提前删除代理端点、自定义验证域名、用户名、路径、IP 地址、令牌和凭据。

Windows 的以下低风险版本信息可以单独提供：

```powershell
Get-AppxPackage -Name OpenAI.Codex | Select-Object Name, Version, Architecture
Get-ExecutionPolicy -List
```
