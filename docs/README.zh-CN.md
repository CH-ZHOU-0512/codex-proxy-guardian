# Codex Proxy Guardian for Windows

这是一个非官方的 Windows 11 当前用户代理守护工具，面向 Microsoft Store / MSIX 版 Codex 桌面端。它持续发现 HTTP/HTTPS 代理，通过多个 OpenAI/ChatGPT HTTPS 目标验证，在代理地址或端口稳定变化后，用进程级代理环境变量和 Chromium 代理参数重新启动 Codex。

本项目与 OpenAI 无隶属、认可或支持关系。这里采用的代理启动方式属于基于实际行为的兼容方案，并不是 Codex 桌面端公开、承诺稳定的接口。

## 安全边界

- 不修改系统代理、WinHTTP 代理、DNS、路由和永久环境变量。
- 只接受带明确端口的 HTTP/HTTPS 代理；拒绝 URL 中嵌入账号密码。
- 候选端点必须同时通过 TCP 监听和经代理的 HTTPS 请求验证。
- 地址变化要经过采样和防抖；重启有冷却时间；每个安装目录只允许一个实例。
- 默认十分钟最多重启三次；达到上限后自动熔断十五分钟，避免异常环境反复重启 Codex。
- 执行受管重启前会先持久化恢复意图；如果新 Codex 进程未能启动，会在同一重启限额内重试，避免无提示地把 Codex 留在关闭状态。
- 同优先级候选使用稳定排序并优先保持当前有效端点，避免多个端口之间来回跳动。
- 定期重新读取 MSIX 清单，Codex 经 Microsoft Store 更新后不依赖旧版本路径。
- 卸载时核对安装标记、任务动作和快捷方式指向，避免删除无关内容。
- 默认 `Safe` 模式只处理“已验证代理发生变化”，不会接管每一次普通方式启动的 Codex。

## 兼容范围

已支持的基线：

- Windows 11 当前用户交互会话；
- Windows PowerShell 5.1；
- Microsoft Store 或企业分发的 Store 签名 MSIX 版 Codex；
- Windows“Internet 设置”中的手动 HTTP/HTTPS 代理；
- 当前进程继承的 `HTTPS_PROXY`、`HTTP_PROXY` 或兼容 HTTP 的 `ALL_PROXY`；
- `config.json` 中指定的 HTTP/HTTPS 代理；
- 常见 Clash/Mihomo、V2Ray/Xray、sing-box、Shadowsocks、NekoRay、Hiddify、FlClash 进程的本机监听端口；
- x64 与 ARM64（从 MSIX 清单解析，不写死安装路径）。

暂不自动支持：PAC/WPAD、纯 SOCKS、只有 TUN 没有 HTTP 混合端口、仅 WinHTTP 的设置、其他用户或服务会话中的监听器，以及企业强制禁止未签名脚本的环境。完整说明见 [SUPPORT.md](SUPPORT.md)。

## 安装

下载并解压 Release ZIP，在普通权限 PowerShell 中执行：

```powershell
Unblock-File .\Install.ps1
.\Install.ps1
```

默认安装到 `%LOCALAPPDATA%\CodexProxyGuardian`，创建当前用户计划任务和“Codex (Managed Proxy)”开始菜单快捷方式。安装过程不会要求管理员权限，也不会改现有网络配置。

默认联网自检失败只会警告，避免代理暂时离线导致无法安装。如需严格检查：

```powershell
.\Install.ps1 -RequireConnectivity
```

## Safe 与 Enforce

- `Safe`：默认。确认代理地址/端口变化后才重启 Codex；普通图标启动的 Codex 不会被强制替换。
- `Enforce`：除上述行为外，还会检查 Codex 根进程是否带当前代理参数，缺失时经防抖后重新启动。

```powershell
.\Install.ps1 -Mode Enforce
```

建议先使用 Safe 模式观察一段时间，再决定是否开启 Enforce。

用户明确点击“Codex (Managed Proxy)”时，如果现有 Codex 根进程缺少当前已验证代理参数，守护程序会在冷却与熔断保护下替换该进程；已经正确受管时不会重复重启。

## 指定代理

编辑 `%LOCALAPPDATA%\CodexProxyGuardian\config.json`：

```json
{
  "ExplicitProxy": "http://127.0.0.1:7890"
}
```

保存后重启“Codex Proxy Guardian”计划任务。留空时自动检查 Windows 当前代理和已识别代理程序的监听端口。

## 状态、故障排查与卸载

```powershell
.\Status.ps1
.\Doctor.ps1 -Online
.\Uninstall.ps1 -Confirm:$false
```

有效性证据分三级：

- `ValidatedProxy`：端口存在，并且经该代理访问多个 HTTPS 目标达到成功数量要求；
- `LaunchConfigured`：Codex 当前根进程带有同一个规范化代理参数；
- `TrafficObserved`：近期实际观察到 Codex 进程树连接这个代理端口。

`TrafficObserved` 是不抓包情况下能提供的最强本机证据，但不代表特定出口 IP、地区或匿名等级。`Doctor.ps1 -Online -Json` 会生成默认脱敏、适合提交 Issue 的报告，不包含原始代理 URL、用户路径和日志正文。

`GuardianState` 会区分 `Stabilizing`、`Ready`、`WaitingForProxy`、`RecoveringCodex`、`RecoveryBlockedByCodex` 和 `RestartCircuitOpen`。`Control.ps1 -Action Start` 会等待正常防抖结束，再报告最终状态。

只重启或停止守护程序，不重启 Codex：

```powershell
.\Control.ps1 -Action Restart
.\Control.ps1 -Action Stop
.\Control.ps1 -Action Start
```

运行日志位于安装目录的 `logs` 文件夹。如果发生频繁重启，先切回 Safe 模式，并按 [TROUBLESHOOTING.md](TROUBLESHOOTING.md) 检查。卸载不会恢复网络配置，因为本项目从未修改这些配置。

开源协议为 [MIT](../LICENSE)，商标与非官方声明见 [DISCLAIMER.md](../DISCLAIMER.md)。
