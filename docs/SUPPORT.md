# 兼容性与支持矩阵

[简体中文](SUPPORT.md) | [English](SUPPORT.en.md)

## 已验证的设计基线

| 项目 | 支持情况 | 说明 |
|---|---|---|
| 操作系统 | Windows 11 | 仅当前用户的交互式桌面会话 |
| 架构 | x64、ARM64 | 从 MSIX 清单解析可执行文件，不写死版本路径 |
| Codex 来源 | Microsoft Store / Store 签名 MSIX | 默认包名为 `OpenAI.Codex`，可以配置其他精确包名 |
| 一键安装器 | Windows 11 自带 .NET Framework 4.8 | 当前用户图形化安装；受企业未签名程序策略限制时使用 ZIP |
| PowerShell | Windows PowerShell 5.1 | PowerShell 7 可运行安装与测试；后台任务使用系统自带 Windows PowerShell |
| 代理协议 | HTTP、HTTPS | 必须包含明确端口 |
| Windows 代理 | 手动 `ProxyServer` | 支持单一端点以及 `http=...;https=...` 形式 |
| 环境变量代理 | `HTTPS_PROXY`、`HTTP_PROXY`、`ALL_PROXY` | 必须表示 HTTP/HTTPS 代理并通过在线验证 |
| 代理程序 | 已识别进程拥有的本地监听器 | 进程匹配规则可以配置 |
| 开机自启 | 当前用户计划任务 | 注册失败时回退到 HKCU Run |

## 暂不自动支持

- PAC 文件、WPAD 或自动配置脚本。正确解析 PAC 需要针对每个目标执行受系统策略影响的 JavaScript。
- 纯 SOCKS4/SOCKS5 端点。当前版本有意只接受 HTTP/HTTPS 代理语义。
- 没有 HTTP 或混合入站端口的纯 TUN 模式。
- 仅设置 WinHTTP 代理的环境。Codex 是桌面应用，读取 WinHTTP 会产生不明确的优先级。
- 位于其他用户或服务会话中，且无法安全归属于当前桌面配置的代理监听器。
- URL 中嵌入认证信息的代理。为避免凭据出现在命令行、进程列表或日志中，此类地址会被拒绝。
- 要求脚本签名或强制使用 Constrained Language Mode 的企业组策略环境。
- 非 MSIX 或第三方改名的 Codex 包，除非配置了精确包名且清单提供可直接启动的可执行文件。

## 提交兼容性报告

提交 Issue 前，请优先生成专门设计的脱敏诊断报告：

```powershell
.\Doctor.ps1 -Online -Json -ExportPath .\codex-proxy-guardian-diagnostics.json
```

同时说明代理软件名称与版本，以及它使用系统代理、HTTP/混合端口还是 TUN 模式。只有产品名称不足以判断实际路由行为。

`Status.ps1 -Json`、`config.json` 和 JSONL 日志属于本机运行数据，**不能视为可直接公开分享的安全内容**。只有维护者明确请求特定字段或事件时才应提交，并提前删除代理端点、自定义验证域名、用户名、路径、IP 地址、令牌和凭据。

以下低风险版本信息可以单独提供：

```powershell
Get-AppxPackage -Name OpenAI.Codex | Select-Object Name, Version, Architecture
Get-ExecutionPolicy -List
```
