# Codex Proxy Guardian

> 让 Codex 始终使用当前有效代理，减少 `Reconnecting 1/5 → 5/5` 后才开始思考的情况。

[简体中文](README.md) · [English](docs/README.en.md)

[![CI](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/actions/workflows/ci.yml/badge.svg)](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/CH-ZHOU-0512/codex-proxy-guardian)](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases/latest) [![License](https://img.shields.io/github/license/CH-ZHOU-0512/codex-proxy-guardian)](LICENSE)

**[下载最新正式版](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases/latest)** · [在线项目页](https://ch-zhou-0512.github.io/codex-proxy-guardian/) · [使用文档](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/wiki) · [问题讨论](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/discussions)

Codex Proxy Guardian 是一个非官方、跨平台的 **Codex 代理守护工具**。它会持续发现并真实验证 HTTP/HTTPS、SOCKS5 和 PAC/WPAD 代理；代理端口变化后，再安全地让 Codex 跟上当前有效端点。

> [!NOTE]
> 它不是代理软件，不提供订阅或节点。你的电脑上需要已有 Clash、Mihomo、v2rayN、sing-box 等可用代理。

## 30 秒看懂

| 你遇到的问题 | Guardian 会做什么 | 你需要做什么 |
|---|---|---|
| 浏览器能上网，Codex 却一直重连 | 验证 Codex 实际需要的代理端点 | 安装一次 |
| 切换节点后端口变了 | 重新发现、防抖、验证，再更新 Codex | Windows/macOS 继续点原图标 |
| 守护脚本让 Codex 反复重启 | 使用冷却、频率限制和熔断 | 保持默认“自动”模式 |
| Linux CLI 没有继承新代理 | 将已验证代理注入新进程 | 用 `codex-guard` 启动 Codex |

[![Codex Proxy Guardian 项目页预览](assets/website-preview.png)](https://ch-zhou-0512.github.io/codex-proxy-guardian/)

## 快速开始

### Windows 11（推荐）

1. 打开[最新正式版](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases/latest)。
2. 下载 `CodexProxyGuardian-Setup-版本号.exe`。
3. 双击安装，以后照常点原来的 Codex 图标。

Guardian 会安装到当前用户、立即启动并随登录静默运行，不需要管理员权限。安装时窗口会显示当前阶段和 0–100% 进度，不再只是一直转圈。

> [!WARNING]
> 项目暂无商业代码签名证书，SmartScreen 可能显示“无法识别”。请只从本仓库 Release 下载；不确定时使用下方 ZIP 方式，不要关闭 Windows 安全功能。

<details>
<summary><strong>Windows ZIP 手动安装</strong></summary>

下载 `CodexProxyGuardian-版本号.zip` 和对应 `.sha256`，解压后在普通权限 PowerShell 中运行：

```powershell
Unblock-File .\Install.ps1
.\Install.ps1
```

如果执行策略不允许：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

</details>

<details>
<summary><strong>macOS（Intel / Apple Silicon）</strong></summary>

从 Release 下载与 CPU 匹配的 `darwin-amd64` 或 `darwin-arm64` 包，解压后运行：

```sh
./install.sh
codex-proxy-guardian doctor
```

安装器会注册当前用户 LaunchAgent。以后照常打开 ChatGPT/Codex。

</details>

<details>
<summary><strong>Linux（x64 / ARM64）</strong></summary>

从 Release 下载 `linux-amd64` 或 `linux-arm64` 包，解压后运行：

```sh
./install.sh
codex-proxy-guardian doctor
codex-guard
```

安装器优先使用 systemd user，不可用时回退到 XDG Autostart。Linux 上请用 `codex-guard` 启动官方 Codex CLI；Guardian 不会强杀或重启交互式终端会话。

</details>

## 安装后怎么用

| 平台 | 日常用法 | 是否要每次手动启动 Guardian |
|---|---|---|
| Windows 11 | 继续点原来的 Codex 图标 | 不需要 |
| macOS | 继续正常打开 ChatGPT/Codex | 不需要 |
| Linux | 用 `codex-guard` 代替 `codex` | 不需要，但 CLI 要由 `codex-guard` 启动 |

Windows 还会安装 **Codex (Managed Proxy)** 快捷方式。普通用户不必每次使用它；它适合想立即、明确地带上已验证代理参数时使用。

## 支持范围

### 平台

| 平台 | 支持的 Codex | 后台自启 | 处理方式 |
|---|---|---|---|
| Windows 11 x64 / ARM64 | Store / MSIX 桌面端 | 计划任务 / HKCU Run | 必要时受控修复桌面端 |
| macOS Intel / Apple Silicon | ChatGPT/Codex 桌面应用 | LaunchAgent | 必要时受控修复桌面应用 |
| Linux x64 / ARM64 | 官方 Codex CLI | systemd user / XDG Autostart | 通过 `codex-guard` 注入代理 |

### 代理类型

| 代理环境 | 支持 | 说明 |
|---|---:|---|
| HTTP / HTTPS / 混合端口 | ✓ | 发现后仍要通过真实 HTTPS 请求 |
| SOCKS5 / SOCKS5H | ✓ | 支持代理端 DNS 解析 |
| 系统 PAC / WPAD | ✓ | 按实际 OpenAI/ChatGPT 目标解析并验证 |
| 手动指定 PAC | ✓ | 使用 `ExplicitPAC` |
| SOCKS4 | — | 安全拒绝 |
| 带账号密码的代理 URL | — | 避免凭据进入配置和日志 |
| 只有 TUN，没有可见代理端点 | — | 没有可注入 Codex 进程的端点 |

PAC 可能为不同目标返回不同路线。只有同一候选达到多目标成功门槛时 Guardian 才会接管；路线互不兼容时保持原状，不猜测。完整细节见[兼容性矩阵](docs/SUPPORT.md)。

## 为什么它不只是“改个端口”

![Codex Proxy Guardian 工作流程：发现、验证、稳定、生效](assets/how-it-works.png)

1. **发现**：读取系统代理、PAC/WPAD、显式配置、环境变量和常见代理程序监听。
2. **真实验证**：不只看端口是否打开，还要经该代理访问多个 HTTPS 目标。
3. **稳定判断**：经过防抖后才确认端点变化，避免被短暂波动误导。
4. **受控生效**：使用进程级环境变量和 Chromium 参数，并受冷却、重启限制和熔断保护。

## 自动还是严格？

| 模式 | 行为 | 适合谁 |
|---|---|---|
| **自动（Safe）** | 先等待并观察真实代理流量；已经能通信就不动 | 绝大多数用户，默认推荐 |
| **严格（Enforce）** | 发现 Codex 缺少当前代理参数时，经防抖后直接受控修复 | 要求启动参数始终严格一致的机器 |

**不确定就保持默认“自动”。** 模式可在 Windows 开始菜单的 **Codex Proxy Guardian Settings** 中切换，不需要手改 JSON，也不会因切换模式而重启 Codex。

## 安全边界

- **不修改**系统代理、WinHTTP、DNS、路由、防火墙或永久环境变量。
- 代理候选必须通过真实网络验证；不按常见端口盲猜协议。
- 默认只信任回环地址和操作系统已配置的远程代理；任意显式远程代理需主动授权。
- PAC 下载、DNS、执行时间、大小和缓存均有上限；WPAD 只在系统已启用时使用。
- 诊断报告默认脱敏，卸载时只删除已核对为本项目所有的资源。

> [!IMPORTANT]
> 本项目与 OpenAI 没有隶属、认可或支持关系。它是基于实际行为的社区兼容方案，不是 Codex 公开且承诺长期稳定的代理 API。

## 如何确认它真的生效

Windows：

```powershell
.\Status.ps1
.\Doctor.ps1 -Online
```

macOS/Linux：

```sh
codex-proxy-guardian status
codex-proxy-guardian doctor
```

| 证据 | 代表什么 |
|---|---|
| `ValidatedProxy` | 代理端口可连接，且真实 HTTPS 请求达到成功门槛 |
| `LaunchConfigured` | Codex 根进程带有同一个规范化代理参数 |
| `TrafficObserved` | 近期观察到 Codex 进程树连接了该代理端点 |

`TrafficObserved` 是不抓包时能提供的最强本地证据，但不代表特定出口 IP、地区或代理规则一定符合预期。完整标准见[兼容性与有效性测试](docs/COMPATIBILITY-TESTING.md)。

## 常见问题

### Codex 还在反复重启

1. 先升级到 v1.4.2 或更高版本；旧版可能把同一混合端口的 HTTP/SOCKS5 波动误判为代理变化。
2. 保持或切回“自动（Safe）”。
3. 运行 `Status.ps1` 查看 `GuardianState` 和最近重启原因。
4. 运行 `Doctor.ps1 -Online` 生成脱敏诊断。
5. 参阅[故障排查](docs/TROUBLESHOOTING.md)或提交 [Bug report](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/issues/new?template=bug_report.yml)。

### Windows 旧版一直说“没有更新”

v1.0.0–v1.3.0 在 Windows PowerShell 5.1 下可能误报 `update_not_available`。请从[最新正式版](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases/latest)手动原位安装一次；已有配置会保留，之后自动更新即可恢复。

### 会不会改坏系统网络？

不会。Guardian 只读取系统代理候选，并管理 Codex 自身的启动环境；它不改写系统代理、DNS、路由或防火墙。

更多解答见 [Wiki FAQ](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/wiki/FAQ)。

<details>
<summary><strong>高级：手动指定代理或 PAC</strong></summary>

配置文件位置：

- Windows：`%LOCALAPPDATA%\CodexProxyGuardian\config.json`
- macOS：`~/Library/Application Support/CodexProxyGuardian/config.json`
- Linux：`${XDG_CONFIG_HOME:-~/.config}/codex-proxy-guardian/config.json`

```json
{
  "ExplicitProxy": "socks5h://127.0.0.1:1080",
  "ExplicitPAC": "",
  "AutomaticUpdates": true,
  "UpdateChannel": "Stable",
  "AllowNonLoopbackProxy": false,
  "AllowSystemNonLoopbackProxy": true
}
```

`ExplicitProxy` 可使用 `http://`、`https://`、`socks5://` 或 `socks5h://`。`ExplicitPAC` 可指定 HTTP/HTTPS PAC URL；macOS/Linux 还接受本地 `file://` PAC。完整字段见 [config.schema.json](config/config.schema.json)。

</details>

<details>
<summary><strong>高级：自动更新、卸载与本地构建</strong></summary>

更新器只信任本仓库 Release，并核对标签、版本、资产名称、包内 `VERSION` 和 SHA-256。

```powershell
.\Control.ps1 -Action CheckUpdate
.\Control.ps1 -Action Update
.\Uninstall.ps1 -Confirm:$false
```

macOS/Linux：

```sh
codex-proxy-guardian update
codex-proxy-guardian update --install
./uninstall.sh
```

本地测试与打包：

```powershell
.\tests\Run-Tests.ps1
.\tools\Package-Release.ps1
```

</details>

## 文档导航

| 想了解什么 | 文档 |
|---|---|
| 从安装到日常使用 | [Wiki：安装与日常使用](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/wiki/Getting-Started) |
| 平台、协议和已知边界 | [兼容性矩阵](docs/SUPPORT.md) |
| 为什么它真的有效 | [兼容性与有效性测试](docs/COMPATIBILITY-TESTING.md) |
| 反复重启、找不到代理、更新失败 | [故障排查](docs/TROUBLESHOOTING.md) |
| 实现原理和信任边界 | [架构说明](docs/ARCHITECTURE.md) |
| 一般疑问 | [Wiki FAQ](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/wiki/FAQ) |

## 参与项目

- [报告问题](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/issues/new?template=bug_report.yml)
- [建议功能](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/issues/new?template=feature_request.yml)
- [参与讨论](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/discussions)
- [贡献代码](CONTRIBUTING.md)

提交反馈前，请不要上传代理账号、节点、IP、令牌或未经人工检查的完整日志。

## 许可证与声明

本项目采用 [MIT 许可证](LICENSE)。“Codex”和“OpenAI”可能是其各自所有者的商标，详见[非官方与商标声明](DISCLAIMER.md)。
