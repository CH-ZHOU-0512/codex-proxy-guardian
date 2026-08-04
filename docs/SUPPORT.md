# 兼容性与支持矩阵

[简体中文](SUPPORT.md) | [English](SUPPORT.en.md)

## 已验证的设计基线

| 平台 | 架构 | Codex 对象 | 系统代理来源 | 当前用户自启 |
|---|---|---|---|---|
| Windows 11 | x64、ARM64 | Store / Store 签名 MSIX 桌面端 | Internet Settings、WinHTTP PAC/WPAD 解析 | 计划任务，失败时 HKCU Run |
| macOS | Intel、Apple Silicon | ChatGPT/Codex 桌面应用 | `scutil --proxy`，含 PAC/WPAD | LaunchAgent |
| Linux | x64、ARM64 | 官方 Codex CLI | GNOME `gsettings`，含自动配置 URL | systemd user，失败时 XDG Autostart |

所有平台支持带明确端口的 HTTP、HTTPS、SOCKS5/SOCKS5H 代理，来源可以是显式配置、继承的 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`、系统代理/PAC/WPAD，或已识别代理进程拥有的回环监听器。未知监听会分别按 HTTP 与 SOCKS5 做真实请求验证，不根据端口号直接认定协议。

PAC 会针对每个 `ProxyTestUrls` 目标执行 `FindProxyForURL`，支持 `PROXY`、`HTTP`、`HTTPS`、`SOCKS`、`SOCKS5` 和 `DIRECT` 回退项。Windows 使用当前用户 WinHTTP 自动代理解析器；macOS/Linux 使用受大小、下载、DNS、执行时间与缓存限制保护的 JavaScript 运行时。返回的端点仍要通过 TCP 与经代理请求成功数门槛。

如果 PAC 为不同验证目标返回互不通用的代理，且没有一个候选能达到配置的成功门槛，Guardian 会保持不接管。这是安全降级，不会为了“看起来支持”而把错误端点强制给 Codex。

## 仍不支持或需要配置

- SOCKS4。PAC 中的 `SOCKS4` 会被忽略；请让代理程序提供 SOCKS5、HTTP 或混合入站。
- 只有 TUN、没有系统 PAC/代理端点，也没有 HTTP/SOCKS5/混合入站的配置。
- URL 中嵌入认证信息的代理。为避免凭据进入命令行、进程列表或日志，此类地址会被拒绝。
- 任意显式或环境变量中的远程代理，除非设置 `AllowNonLoopbackProxy: true`。操作系统已经配置的远程代理由独立的 `AllowSystemNonLoopbackProxy` 控制，默认开启，可关闭。
- 位于其他用户或服务会话中，且无法安全归属于当前桌面配置的代理监听器。
- 要求脚本签名或强制 Constrained Language Mode 的企业组策略环境。
- 非 MSIX 或第三方改名的 Windows Codex 包，除非配置精确包名且清单提供可启动文件。
- Linux Codex 桌面端。OpenAI 当前没有发布官方 Linux 桌面应用；Linux 版为官方 Codex CLI 提供 `codex-guard`。
- 对已启动的 Linux 终端补写环境，或自动结束/重启交互式 Codex CLI。
- macOS 自定义应用路径未加入 `MacApplicationPaths` 的桌面应用。

## 提交兼容性报告

macOS/Linux：

```sh
codex-proxy-guardian doctor
```

Windows：

```powershell
.\Doctor.ps1 -Online -Json -ExportPath .\codex-proxy-guardian-diagnostics.json
```

请同时说明代理软件版本和实际模式：HTTP、混合、纯 SOCKS5、PAC/WPAD 或 TUN。只有产品名称不足以判断路由行为。

`Status.ps1 -Json`、`config.json` 和 JSONL 日志不是默认可公开内容；提交前应删除代理端点、自定义域名、用户名、路径、IP、令牌和凭据。
