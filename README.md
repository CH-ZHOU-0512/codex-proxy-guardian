# Codex Proxy Guardian：Windows 11 Codex 桌面版代理守护程序

[简体中文](README.md) | [English](docs/README.en.md)

![Codex Proxy Guardian：让 Codex 不再因为代理没有跟上而反复重连](assets/social-preview.png)

[![CI](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/actions/workflows/ci.yml/badge.svg)](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/CH-ZHOU-0512/codex-proxy-guardian?include_prereleases)](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases)
[![License](https://img.shields.io/github/license/CH-ZHOU-0512/codex-proxy-guardian)](LICENSE)

> **一句话解释：** 如果你的 Codex 经常要重连四五次才开始思考，而原因是代理没有正确跟上，这个工具就是用来解决它的。

这是一个非官方的 **Windows 11 Codex 桌面版代理守护工具**。它能够持续发现并验证当前可用的 HTTP/HTTPS 代理；当 Clash、Mihomo、v2rayN、sing-box 等代理软件的监听地址或端口稳定变化后，为 Codex 配置当前代理并进行受控重启。

项目重点解决这些实际问题：**Codex 桌面端无法连接、系统代理端口变化、代理软件随机端口、Codex 没有继承代理、切换节点后 Codex 仍使用旧代理、守护脚本导致 Codex 反复重启**。

## 为什么需要它

许多 Windows 代理软件会在电脑本地开启一个 HTTP 代理端口，例如 `127.0.0.1:7890`，其他应用只有连接这个端口才能使用代理。浏览器能够正常联网，并不一定代表已经运行的 Codex 也拿到了正确代理；代理软件重启、切换配置或更新后，端口还可能发生变化，而 Codex 仍然记着旧地址，于是就会出现登录失败、内容加载不出来或任务中断。

手动处理通常需要找到当前端口、关闭 Codex、设置代理环境变量或启动参数，再重新打开 Codex；以后端口变化还要重复操作。Codex Proxy Guardian 把这套过程自动化：它寻找候选端口、实际验证代理是否可用，只在确认变化稳定后才更新 Codex，并通过防抖、冷却和熔断避免反复重启。即使不熟悉端口、环境变量或计划任务，也可以先使用默认的 `Safe` 模式。

> [!NOTE]
> 本项目本身**不是代理软件，也不提供代理服务或节点**。使用前需要电脑上已经存在一个可用的 HTTP/HTTPS 代理；它解决的是“怎样让 Codex 稳定跟随这个代理”的问题。

![Codex Proxy Guardian 工作流程：发现、验证、稳定、生效](assets/how-it-works.png)

> [!IMPORTANT]
> 本项目是独立的社区项目，与 OpenAI 没有隶属、认可或支持关系。项目使用的是基于实际行为的兼容方案，并非 Codex 桌面端公开且承诺长期稳定的代理 API。

## 它能做什么

- 自动读取 Windows 当前用户的系统代理、显式指定代理、进程环境变量和常见代理程序的本地监听端口。
- 不只判断端口是否存在，还会通过代理访问多个 OpenAI/ChatGPT HTTPS 目标，达到成功数量要求后才启用。
- 使用进程级 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 环境变量和 Chromium `--proxy-server` 参数启动 Codex。
- 代理地址或端口变化时先防抖，再受控重启 Codex；端口来回波动时不会立即反复重启。
- 提供重启冷却、十分钟重启次数限制、熔断和启动失败恢复，避免形成 Codex 重启循环。
- 自动适配 Microsoft Store / MSIX 版 Codex 更新后的安装路径，并支持 x64 和 ARM64。
- 以当前用户身份静默运行、登录后自启，不要求管理员权限。
- 提供状态、日志、在线诊断、单实例保护和安全卸载脚本。

## 先看安全边界

- **不会修改** Windows 系统代理、WinHTTP 代理、DNS、路由或永久用户/系统环境变量。
- 只接受带明确端口的 HTTP/HTTPS 代理；拒绝 URL 中包含账号密码的代理地址。
- 候选代理必须同时通过 TCP 监听检查和经代理发起的 HTTPS 请求验证。
- 默认使用 `Safe` 模式：只有在代理已经验证、Codex 缺少当前代理参数，而且证据等待期内没有观察到该进程正在使用当前代理时，才会进行一次受控修复。
- 卸载时会核对安装标记、计划任务动作和快捷方式目标，只删除本项目拥有的资源。
- 诊断报告默认脱敏，不包含原始代理 URL、用户名路径或日志正文；提交 Issue 前仍建议人工检查一次。

## 支持范围

当前支持的基础环境：

- Windows 11 当前用户的交互式桌面会话；
- Windows PowerShell 5.1 或 PowerShell 7 安装环境；后台任务使用系统自带的 Windows PowerShell 5.1；
- Microsoft Store 或企业分发的 Store 签名 MSIX 版 Codex 桌面端；
- Windows“Internet 设置”中的显式 HTTP/HTTPS 系统代理；
- `config.json` 中手动指定的 HTTP/HTTPS 代理；
- 当前进程继承的 `HTTPS_PROXY`、`HTTP_PROXY` 或兼容 HTTP 的 `ALL_PROXY`；
- Clash/Mihomo、v2rayN/Xray、sing-box、Shadowsocks、NekoRay、Hiddify、FlClash 等常见代理程序的本机监听端口；
- x64 与 ARM64，Codex 路径从 MSIX 清单动态解析，不写死版本目录。

暂不自动支持：PAC/WPAD、纯 SOCKS 代理、只有 TUN 而没有 HTTP/混合端口的配置、仅 WinHTTP 代理、其他用户或服务会话中的监听器，以及企业策略禁止未签名 PowerShell 脚本的环境。详见[兼容性矩阵](docs/SUPPORT.md)。

## 下载与安装

从 [Releases 发布页面](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases)下载最新 ZIP 并解压。不要直接下载 GitHub 自动生成的 `Source code` 压缩包，因为正式 Release ZIP 已经过测试、打包并附带 SHA-256 校验文件。

在**普通权限、非管理员** PowerShell 中进入解压目录并执行：

```powershell
Unblock-File .\Install.ps1
.\Install.ps1
```

如果本机执行策略不允许直接运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

默认安装到 `%LOCALAPPDATA%\CodexProxyGuardian`，并创建：

- 当前用户计划任务 `Codex Proxy Guardian`，用于登录后静默启动；
- 开始菜单快捷方式 **Codex (Managed Proxy)**，用于明确地以当前有效代理启动 Codex。

### 安装后怎么使用

**只需要先运行一次安装脚本。** 除非安装时使用了 `-NoStart`，守护程序会在安装完成后立即启动，并在以后登录 Windows 时自动静默运行；不需要每次打开 PowerShell，也不需要手动先启动守护程序。

默认 `Safe` 模式也会检查从原图标打开的 Codex：如果它缺少当前代理参数，Guardian 会先等待证据；等待期间如果观察到该进程已经在通过当前代理通信，就保持不动，否则只进行一次受控重启。开始菜单中的 **Codex (Managed Proxy)** 仍然是立即、明确地使用已验证代理的方式，但不再是普通用户每次启动 Codex 的必选动作。

如果希望不考虑流量证据，只要发现 Codex 缺少当前代理参数就进行校正，可以在确认 `Safe` 模式运行稳定后改用 `Enforce`。简化理解如下：

| 你的操作 | 是否需要额外动作 |
|---|---|
| 首次安装 | 运行一次 `Install.ps1` |
| 直接点击原来的 Codex 图标 | 不需要；Safe 会先观察，必要时自动受控重启一次 |
| 希望立即确定代理参数已经带上 | 点击开始菜单中的 **Codex (Managed Proxy)** |
| 以后启动守护程序 | 不需要；它会登录后自动静默运行 |
| 希望严格校正所有缺少代理参数的启动 | 稳定使用后改为 `Enforce` 模式 |

安装时会进行联网自检。代理暂时离线默认只产生警告；如需把连通性作为安装的硬性条件：

```powershell
.\Install.ps1 -RequireConnectivity
```

需要在尚未安装 Codex 的电脑上提前部署时：

```powershell
.\Install.ps1 -AllowMissingCodex -NoStart
```

## Safe 与 Enforce 模式

| 模式 | 行为 | 建议 |
|---|---|---|
| `Safe` | 普通 Codex 缺少代理参数时先等待 20 秒并观察实际代理流量；已经能通信就不动，否则受控重启一次 | 默认，适合绝大多数用户 |
| `Enforce` | 普通 Codex 缺少当前代理参数时，经防抖后直接受控重启，不以流量证据豁免 | 需要严格、确定的启动参数时开启 |

直观地说：**Safe 是“先证明有必要再接管”，Enforce 是“参数不一致就接管”。** 两种模式都受到防抖、冷却、重启次数限制和熔断保护。

安装或更新时开启 Enforce：

```powershell
.\Install.ps1 -Mode Enforce
```

项目通过匹配 Codex **根进程**的代理参数，而不是匹配短暂存在的启动器 PID，来规避早期脚本常见的误判重启问题。所有重启仍受到防抖、冷却、频率限制和熔断保护。

Codex 更新后，Guardian 会重新读取当前用户的 MSIX 清单，根据应用 ID、常见可执行文件名和完整路径重新解析根进程，并在短时间内同时识别更新前后的路径。如果更新期间暂时找不到新的可执行文件，它会保留仍在运行的 Codex，而不是先关闭再尝试启动。`Status.ps1` 和脱敏 `Doctor.ps1` 报告会显示解析方式、Codex 版本、架构和外部启动策略，方便社区反馈不同机器上的真实结果。

当前项目仍处于 Alpha 阶段，无法承诺未来 Codex 或 Windows 更新完全不改变启动行为；但解析失败会显示为明确状态，不会通过猜测路径去终止其他进程。

## 指定代理

编辑 `%LOCALAPPDATA%\CodexProxyGuardian\config.json`：

```json
{
  "ExplicitProxy": "http://127.0.0.1:7890",
  "AllowNonLoopbackProxy": false,
  "ManageExternalCodexLaunches": false,
  "SafeRepairExternalCodexLaunches": true,
  "SafeExternalLaunchGraceSeconds": 20,
  "DebounceSeconds": 10,
  "RestartCooldownSeconds": 45
}
```

`ExplicitProxy` 优先级最高。留空时会自动检查 Windows 当前代理、继承的代理环境变量和已识别代理程序的监听端口。完整选项见 [default-config.json](config/default-config.json) 和 [config.schema.json](config/config.schema.json)。

修改配置后重启守护程序：

```powershell
.\Control.ps1 -Action Restart
```

这只会重启守护程序，不会修改 Windows 网络配置。

## 如何确认它真的有效

```powershell
.\Status.ps1
.\Status.ps1 -Json
.\Doctor.ps1 -Online
```

状态中包含三级有效性证据：

| 证据 | 含义 |
|---|---|
| `ValidatedProxy` | 代理端口可连接，并且经代理访问配置的 HTTPS 测试目标达到成功数量要求 |
| `LaunchConfigured` | 当前 Codex 根进程带有同一个规范化代理参数 |
| `TrafficObserved` | 近期实际观察到 Codex 进程树连接了这个代理端点 |

`TrafficObserved` 是不进行抓包时项目能够提供的最强本地证据，但它不代表特定出口 IP、地区、匿名等级或代理规则一定符合预期。需要提交兼容性反馈时运行：

```powershell
.\Doctor.ps1 -Online -Json
```

`GuardianState` 会区分 `Stabilizing`、`Ready`、`WaitingForProxy`、`RecoveringCodex`、`RecoveryBlockedByCodex` 和 `RestartCircuitOpen` 等状态。完整验证标准见[兼容性与有效性测试](docs/COMPATIBILITY-TESTING.md)。

## Codex 反复重启怎么办

重启频率达到上限后，熔断器会阻止继续重启。建议：

1. 保持或切回默认的 `Safe` 模式；
2. 运行 `.\Status.ps1` 查看 `GuardianState` 和最近重启原因；
3. 运行 `.\Doctor.ps1 -Online` 检查代理验证和 Codex 启动参数；
4. 按[故障排查文档](docs/TROUBLESHOOTING.md)处理；
5. 仍无法解决时，提交经过人工复核的脱敏诊断报告。

## 日志与控制

```powershell
.\Control.ps1 -Action Start
.\Control.ps1 -Action Stop
.\Control.ps1 -Action Restart
```

运行状态保存在安装目录的 `status.json`，每日 JSON Lines 日志位于 `logs`。日志按大小、保留天数和文件数轮转。项目不会接受或记录代理账号密码。

## 卸载

在 Release 解压目录或安装目录执行：

```powershell
.\Uninstall.ps1 -Confirm:$false
```

如需将日志保留到安装目录之外：

```powershell
.\Uninstall.ps1 -KeepLogs -Confirm:$false
```

卸载程序不会“恢复网络设置”，因为本项目从未修改这些设置。

## 参与测试与贡献

不同代理软件、端口模式和 Codex 分发版本之间存在差异。欢迎在不泄露代理地址、IP、用户名、令牌和日志隐私的前提下，提交兼容性反馈。

- 报告问题：使用中文 [Bug report](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/issues/new?template=bug_report.yml)
- 建议新功能：使用中文 [Feature request](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/issues/new?template=feature_request.yml)
- 贡献代码：参阅 [CONTRIBUTING.md](CONTRIBUTING.md)

本地构建与测试：

```powershell
.\tests\Run-Tests.ps1
.\tools\Package-Release.ps1
```

## 许可证与声明

本项目采用 [MIT 许可证](LICENSE)。“Codex”和“OpenAI”可能是其各自所有者的商标，详见[非官方与商标声明](DISCLAIMER.md)。
