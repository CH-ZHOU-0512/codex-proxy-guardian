# Codex Proxy Guardian：让 Codex 始终跟上当前有效代理

[简体中文](README.md) | [English](docs/README.en.md)

[![Codex Proxy Guardian 在线项目页：别再重连五次，才开始思考](assets/website-preview.png)](https://ch-zhou-0512.github.io/codex-proxy-guardian/)

**[打开在线项目主页 →](https://ch-zhou-0512.github.io/codex-proxy-guardian/)**　|　[下载最新正式版](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases/latest)　|　[查看使用文档](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/wiki)

[![CI](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/actions/workflows/ci.yml/badge.svg)](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/CH-ZHOU-0512/codex-proxy-guardian?include_prereleases)](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases)
[![License](https://img.shields.io/github/license/CH-ZHOU-0512/codex-proxy-guardian)](LICENSE)

> **一句话解释：** 如果你的 Codex 经常要重连四五次才开始思考，而原因是代理没有正确跟上，这个工具就是用来解决它的。

这是一个非官方的 **Codex 代理守护工具**，支持 Windows 11、macOS 和 Linux。它持续发现并验证当前可用的 HTTP/HTTPS 代理；当 Clash、Mihomo、v2rayN、sing-box 等代理软件的监听地址或端口稳定变化后，让 Codex 使用新的有效端点。

| 平台 | 守护对象 | 安装后怎么用 |
|---|---|---|
| Windows 11 | Store/MSIX Codex 桌面端 | 继续点击原来的 Codex 图标；必要时自动受控修复 |
| macOS（Intel / Apple Silicon） | ChatGPT/Codex 桌面应用 | 继续正常打开应用；必要时自动受控修复 |
| Linux（x64 / ARM64） | Codex CLI | 用 `codex-guard` 代替 `codex` 启动；不会强杀或重启终端会话 |

项目重点解决这些实际问题：**Codex 桌面端无法连接、系统代理端口变化、代理软件随机端口、Codex 没有继承代理、切换节点后 Codex 仍使用旧代理、守护脚本导致 Codex 反复重启**。

## 为什么需要它

许多代理软件会在电脑本地开启一个 HTTP 代理端口，例如 `127.0.0.1:7890`，其他应用只有连接这个端口才能使用代理。浏览器能够正常联网，并不一定代表已经运行的 Codex 也拿到了正确代理；代理软件重启、切换配置或更新后，端口还可能发生变化，而 Codex 仍然记着旧地址，于是就会出现登录失败、内容加载不出来或任务中断。

手动处理通常需要找到当前端口、关闭 Codex、设置代理环境变量或启动参数，再重新打开 Codex；以后端口变化还要重复操作。Codex Proxy Guardian 把这套过程自动化：它寻找候选端口、实际验证代理是否可用，只在确认变化稳定后才更新 Codex，并通过防抖、冷却和熔断避免反复重启。即使不熟悉端口、环境变量或计划任务，也可以先使用默认的 `Safe` 模式。

> [!NOTE]
> 本项目本身**不是代理软件，也不提供代理服务或节点**。使用前需要电脑上已经存在一个可用的 HTTP/HTTPS 代理；它解决的是“怎样让 Codex 稳定跟随这个代理”的问题。

![Codex Proxy Guardian 工作流程：发现、验证、稳定、生效](assets/how-it-works.png)

> [!IMPORTANT]
> 本项目是独立的社区项目，与 OpenAI 没有隶属、认可或支持关系。项目使用的是基于实际行为的兼容方案，并非 Codex 桌面端公开且承诺长期稳定的代理 API。

## 它能做什么

- 自动读取 Windows、macOS 或 GNOME 当前用户代理、显式指定代理、进程环境变量和常见代理程序的本地监听端口。
- 不只判断端口是否存在，还会通过代理访问多个 OpenAI/ChatGPT HTTPS 目标，达到成功数量要求后才启用。
- 使用进程级 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 环境变量和 Chromium `--proxy-server` 参数启动 Codex。
- 代理地址或端口变化时先防抖，再受控重启 Codex；端口来回波动时不会立即反复重启。
- 提供重启冷却、十分钟重启次数限制、熔断和启动失败恢复，避免形成 Codex 重启循环。
- Windows 自动适配 Store/MSIX Codex 更新后的安装路径；macOS 支持 Intel 与 Apple Silicon；Linux 支持 x64 与 ARM64。
- 每日检查本项目 GitHub Release，只有版本、文件名和 SHA-256 全部匹配时才静默原位升级。
- Windows 提供单文件图形化安装器；macOS/Linux 提供当前用户安装脚本，均无需管理员或 `sudo`。
- 以当前用户身份静默运行、登录后自启，不要求管理员权限。
- 提供开始菜单设置窗口、状态、日志、在线诊断、单实例保护和安全卸载脚本。

## 先看安全边界

- **不会修改**系统代理、WinHTTP 代理、DNS、路由、防火墙或永久用户/系统环境变量。
- 只接受带明确端口的 HTTP/HTTPS 代理；拒绝 URL 中包含账号密码的代理地址。
- 候选代理必须同时通过 TCP 监听检查和经代理发起的 HTTPS 请求验证。
- 默认使用“自动（Safe）”模式：只有在代理已经验证、Codex 缺少当前代理参数，而且证据等待期内没有观察到该进程正在使用当前代理时，才会进行一次受控修复。
- 卸载时会核对安装标记、计划任务动作和快捷方式目标，只删除本项目拥有的资源。
- 诊断报告默认脱敏，不包含原始代理 URL、用户名路径或日志正文；提交 Issue 前仍建议人工检查一次。

## 支持范围

| 项目 | Windows 11 | macOS | Linux |
|---|---|---|---|
| 架构 | x64、ARM64 | Intel、Apple Silicon | x64、ARM64 |
| Codex | Store/MSIX 桌面端 | ChatGPT/Codex 桌面应用 | 官方 Codex CLI |
| 系统代理发现 | Internet Settings | `scutil --proxy` | GNOME `gsettings`；其他桌面建议显式配置 |
| 后台自启 | 当前用户计划任务 / HKCU Run | 当前用户 LaunchAgent | systemd user / XDG Autostart |
| 自动处理 Codex | 可受控重启桌面端 | 可受控重启桌面应用 | 只维护代理；不重启交互式 CLI |

共同支持显式 HTTP/HTTPS 代理、继承的 `HTTPS_PROXY` / `HTTP_PROXY` / HTTP 兼容 `ALL_PROXY`，以及常见代理程序的本机监听端口。暂不自动支持 PAC/WPAD、纯 SOCKS、只有 TUN 而没有 HTTP/混合端口的配置，或 URL 中包含账号密码的代理。详见[兼容性矩阵](docs/SUPPORT.md)。

> [!IMPORTANT]
> OpenAI 当前提供 macOS/Windows 桌面应用和 Linux Codex CLI；Linux 没有官方 Codex 桌面应用。因此 Linux 版采用 `codex-guard` 包装 CLI，并明确不声称能守护不存在的桌面端。参阅 [Codex app](https://learn.chatgpt.com/docs/app) 和 [Codex CLI quickstart](https://learn.chatgpt.com/docs/quickstart)。

## 下载与安装

### macOS

从[最新正式版](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases/latest)按芯片下载：

- Apple Silicon（M1/M2/M3/M4 等）：`CodexProxyGuardian-版本-darwin-arm64.tar.gz`
- Intel Mac：`CodexProxyGuardian-版本-darwin-amd64.tar.gz`

解压后在终端进入 `CodexProxyGuardian` 目录，以普通用户执行：

```sh
./install.sh
codex-proxy-guardian doctor
```

安装器复制到 `~/.local/lib/codex-proxy-guardian`，注册当前用户 LaunchAgent 并立即静默启动。以后照常打开 ChatGPT/Codex；代理稳定变化或应用未带当前参数时，Guardian 才会在防抖、冷却和熔断限制内受控修复。

### Linux

从同一 Release 按架构下载 `linux-amd64.tar.gz` 或 `linux-arm64.tar.gz`，解压后执行：

```sh
./install.sh
codex-proxy-guardian doctor
codex-guard
```

安装器优先注册 systemd 用户服务，不可用时回退到 XDG Autostart，不使用 `sudo`。`codex-guard` 会先取出 Guardian 已验证的代理，再以进程级环境变量启动官方 Codex CLI，并保留原终端和参数：例如 `codex-guard resume --last`。

> 直接运行普通 `codex` 时，已经由 shell 正确配置代理的环境仍可正常工作；但 Guardian 无法在进程启动后改写另一个终端进程的环境。因此 Linux 上要确定使用当前已验证代理，请使用 `codex-guard`。Guardian 永远不会自动结束或重启交互式 Codex CLI 会话。

### Windows 11：推荐双击 EXE 一键安装

1. 打开[最新正式版下载页](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases/latest)，下载名称以 `CodexProxyGuardian-Setup-` 开头、以 `.exe` 结尾的文件；
2. 双击 EXE，确认界面显示的项目地址为 `CH-ZHOU-0512/codex-proxy-guardian`；
3. 点击“立即安装”。完成后 Guardian 已在后台运行，以后照常点击原来的 Codex 图标即可。

一键安装器只安装到当前用户，不会请求管理员权限，也不会修改 Windows 系统代理、WinHTTP、DNS、路由或永久环境变量。它内嵌经过同一次 CI 构建的正式 Release ZIP，并在运行前检查版本和必需文件。

> [!WARNING]
> 当前项目没有商业代码签名证书，因此 Windows SmartScreen 可能显示“Windows 已保护你的电脑”。请只从本仓库的正式 Release 下载；介意此提示或无法确认来源时，请使用下面的 ZIP 手动安装方式。不要关闭系统安全功能。

需要核对下载完整性时，同时下载 EXE 对应的 `.sha256` 文件，并比较以下命令输出的哈希：

```powershell
Get-FileHash .\CodexProxyGuardian-Setup-*.exe -Algorithm SHA256
Get-Content .\CodexProxyGuardian-Setup-*.exe.sha256
```

### 备用：ZIP 手动安装

从同一 Release 下载 `CodexProxyGuardian-版本号.zip` 及对应 `.sha256`，解压后在**普通权限、非管理员** PowerShell 中进入目录并执行。不要使用 GitHub 自动生成的 `Source code` 压缩包。

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
- 每日计划任务 `Codex Proxy Guardian Update`，用于检查并校验 GitHub Release；
- 开始菜单快捷方式 **Codex (Managed Proxy)**，用于明确地以当前有效代理启动 Codex；
- 开始菜单快捷方式 **Codex Proxy Guardian Settings**，用于切换模式、自动更新和更新通道。

### 安装后怎么使用

**只需要安装一次。** 守护程序会在安装完成后立即启动，并在以后登录 Windows 时自动静默运行；不需要每次打开 PowerShell，也不需要手动先启动守护程序。ZIP 高级安装只有在使用 `-NoStart` 时才不会立即启动。

默认“自动（Safe）”模式也会检查从原图标打开的 Codex：如果它缺少当前代理参数，Guardian 会先等待证据；等待期间如果观察到该进程已经在通过当前代理通信，就保持不动，否则只进行一次受控重启。开始菜单中的 **Codex (Managed Proxy)** 仍然是立即、明确地使用已验证代理的方式，但不再是普通用户每次启动 Codex 的必选动作。

模式不再需要手改 `config.json`。从开始菜单打开 **Codex Proxy Guardian Settings**，选择“自动（推荐）”或“严格”并应用即可。简化理解如下：

| 你的操作 | 是否需要额外动作 |
|---|---|
| 首次安装 | 推荐双击 Release 中的 Setup EXE；也可运行一次 `Install.ps1` |
| 直接点击原来的 Codex 图标 | 不需要；自动模式会先观察，必要时受控重启一次 |
| 希望立即确定代理参数已经带上 | 点击开始菜单中的 **Codex (Managed Proxy)** |
| 以后启动守护程序 | 不需要；它会登录后自动静默运行 |
| 希望严格校正所有缺少代理参数的启动 | 在设置窗口选择“严格” |
| 项目发布新版本 | 默认每日自动检查，SHA-256 校验通过后原位升级 |

安装时会进行联网自检。代理暂时离线默认只产生警告；如需把连通性作为安装的硬性条件：

```powershell
.\Install.ps1 -RequireConnectivity
```

需要在尚未安装 Codex 的电脑上提前部署时：

```powershell
.\Install.ps1 -AllowMissingCodex -NoStart
```

## 自动与严格模式

| 用户看到的模式 | 内部模式 | 行为 | 建议 |
|---|---|---|---|
| 自动 | `Safe` | 缺少参数时先等待 20 秒并观察实际代理流量；已经能通信就不动，否则受控修复一次 | 默认，适合绝大多数用户 |
| 严格 | `Enforce` | 缺少当前代理参数时，经防抖后直接受控修复，不以流量证据豁免 | 需要严格、确定的启动参数时开启 |

直观地说：**自动是“先证明有必要再接管”，严格是“参数不一致就接管”。** 两种模式都受到防抖、冷却、重启次数限制和熔断保护。程序不会自行把用户的长期策略从自动改成严格；“自动”是在每次 Codex 启动时根据真实证据做决定。

无需打开设置窗口时，也可以一条命令切换：

```powershell
.\Control.ps1 -Action SetMode -Mode Auto
.\Control.ps1 -Action SetMode -Mode Strict
.\Control.ps1 -Action ToggleMode
```

macOS/Linux 使用同样的两种策略：

```sh
codex-proxy-guardian mode auto
codex-proxy-guardian mode strict
```

模式变化会由 Guardian 在后台自动重新加载，不需要重启 Guardian，也不会主动关闭当前 Codex。

项目通过匹配 Codex **根进程**的代理参数，而不是匹配短暂存在的启动器 PID，来规避早期脚本常见的误判重启问题。所有重启仍受到防抖、冷却、频率限制和熔断保护。

Codex 更新后，Guardian 会重新读取当前用户的 MSIX 清单，根据应用 ID、常见可执行文件名和完整路径重新解析根进程，并在短时间内同时识别更新前后的路径。如果更新期间暂时找不到新的可执行文件，它会保留仍在运行的 Codex，而不是先关闭再尝试启动。`Status.ps1` 和脱敏 `Doctor.ps1` 报告会显示解析方式、Codex 版本、架构和外部启动策略，方便社区反馈不同机器上的真实结果。

`v1.0.0` 是首个正式版本。Codex 或 Windows 后续更新仍可能改变进程启动行为，社区工具需要持续跟进；解析失败会显示为明确状态，不会通过猜测路径去终止其他进程。

## 指定代理

配置文件位置：

- Windows：`%LOCALAPPDATA%\CodexProxyGuardian\config.json`
- macOS：`~/Library/Application Support/CodexProxyGuardian/config.json`
- Linux：`${XDG_CONFIG_HOME:-~/.config}/codex-proxy-guardian/config.json`

编辑对应的 `config.json`：

```json
{
  "ExplicitProxy": "http://127.0.0.1:7890",
  "AutomaticUpdates": true,
  "UpdateChannel": "Stable",
  "AllowNonLoopbackProxy": false,
  "ManageExternalCodexLaunches": false,
  "SafeRepairExternalCodexLaunches": true,
  "SafeExternalLaunchGraceSeconds": 20,
  "DebounceSeconds": 10,
  "RestartCooldownSeconds": 45
}
```

`ExplicitProxy` 优先级最高。留空时会自动检查当前平台系统代理、继承的代理环境变量和已识别代理程序的监听端口。Windows 完整选项见 [default-config.json](config/default-config.json) 与 [config.schema.json](config/config.schema.json)，macOS/Linux 默认值见 [default-posix-config.json](config/default-posix-config.json)。

修改配置后重启守护程序：

```powershell
.\Control.ps1 -Action Restart
```

这只会重启守护程序，不会修改 Windows 网络配置。

## 自动更新

默认每天由当前用户计划任务检查一次 GitHub Release。更新器只信任固定仓库 `CH-ZHOU-0512/codex-proxy-guardian`，要求 Release 标签、ZIP 文件名、包内 `VERSION` 完全一致，并使用同一 Release 附带的 `.sha256`（以及 GitHub 提供时的资产摘要）校验下载内容。安装前会快照现有文件，拒绝路径异常或展开规模超限的压缩包；安装中断会尝试恢复原版本并重新启动原 Guardian。结果写入 `logs\update-*.jsonl`。

macOS/Linux 由守护进程每天检查与当前系统、架构精确对应的 `.tar.gz` 和 `.sha256`，验证标签、版本、文件名、包内 `VERSION`、SHA-256 与安全解包边界后才原位替换。更新成功后进程会无缝执行新版；失败则继续使用旧版或保留 `.previous` 回退副本。

在设置窗口可以关闭自动更新，或在命令行检查/立即更新：

```powershell
.\Control.ps1 -Action CheckUpdate
.\Control.ps1 -Action Update
```

macOS/Linux：

```sh
codex-proxy-guardian update
codex-proxy-guardian update --install
```

新安装默认使用 `Stable` 通道；愿意提前测试 Alpha/Beta 的用户可以在设置窗口主动改为“预发布版本”。升级会保留已有通道选择和其他配置，并优先接管正在运行的 Codex 会话而不是重启它。

## 如何确认它真的有效

macOS/Linux：

```sh
codex-proxy-guardian status
codex-proxy-guardian status --json
codex-proxy-guardian doctor
```

Windows：

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

1. 保持或切回默认的“自动（Safe）”模式；
2. 运行 `.\Status.ps1` 查看 `GuardianState` 和最近重启原因；
3. 运行 `.\Doctor.ps1 -Online` 检查代理验证和 Codex 启动参数；
4. 按[故障排查文档](docs/TROUBLESHOOTING.md)处理；
5. 仍无法解决时，提交经过人工复核的脱敏诊断报告。

## 日志与控制

macOS/Linux 的运行状态和轮转 JSONL 日志分别位于：

- macOS：`~/Library/Application Support/CodexProxyGuardian/`
- Linux：`${XDG_STATE_HOME:-~/.local/state}/codex-proxy-guardian/`

常用命令为 `codex-proxy-guardian status`、`doctor`、`mode` 和 `update`。Linux 用 `codex-guard` 启动 Codex CLI。

Windows 控制命令：

```powershell
.\Control.ps1 -Action Start
.\Control.ps1 -Action Stop
.\Control.ps1 -Action Restart
.\Control.ps1 -Action SetMode -Mode Auto
.\Control.ps1 -Action CheckUpdate
```

运行状态保存在安装目录的 `status.json`，每日 JSON Lines 日志位于 `logs`。日志按大小、保留天数和文件数轮转。项目不会接受或记录代理账号密码。

## 卸载

macOS/Linux 在下载包的 `CodexProxyGuardian` 目录执行：

```sh
./uninstall.sh
```

默认保留配置和日志；确实需要一并删除时使用 `./uninstall.sh --purge`。脚本会先核对服务和可执行文件归属，不会修改或“恢复”系统网络设置。

Windows 在 Release 解压目录或安装目录执行：

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
