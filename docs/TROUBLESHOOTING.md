# 故障排查

[简体中文](TROUBLESHOOTING.md) | [English](TROUBLESHOOTING.en.md)

## macOS/Linux 先运行这三条

```sh
codex-proxy-guardian version
codex-proxy-guardian status
codex-proxy-guardian doctor
```

如果命令不存在，把 `~/.local/bin` 加入当前 shell 的 `PATH`，或者直接运行 `~/.local/lib/codex-proxy-guardian/codex-proxy-guardian`。日志位于 macOS 的 `~/Library/Application Support/CodexProxyGuardian/logs`，或 Linux 的 `${XDG_STATE_HOME:-~/.local/state}/codex-proxy-guardian/logs`。

### Linux 直接运行 `codex` 没有走 Guardian

这是预期的平台边界。一个后台进程不能安全地改写已经启动的终端进程环境。请运行 `codex-guard`，它会把 Guardian 当前已验证的代理注入新启动的 Codex CLI，并透传参数。Guardian 不会结束或重启交互式 CLI 会话。

### Linux 显示 `WaitingForProxy`

确认代理软件开放 HTTP、SOCKS5 或混合端口。只有 TUN 且没有系统 PAC/代理端点时仍无法明确验证。非 GNOME 桌面可能没有统一的系统代理读取方式，可编辑 `${XDG_CONFIG_HOME:-~/.config}/codex-proxy-guardian/config.json` 设置：

```json
{ "ExplicitProxy": "http://127.0.0.1:7890" }
```

### macOS 找不到桌面应用

`doctor` 或 `status` 显示 `CodexApplicationUnavailable` 时，确认 ChatGPT/Codex 位于 `/Applications` 或 `~/Applications`。自定义位置需要加入配置的 `MacApplicationPaths`。Guardian 不会通过模糊进程名去关闭未知程序。

### macOS/Linux 后台没有自启

- macOS：运行 `launchctl print gui/$(id -u)/io.github.ch-zhou-0512.codex-proxy-guardian`；重新执行 `./install.sh` 可修复当前用户 LaunchAgent。
- Linux systemd：运行 `systemctl --user status codex-proxy-guardian.service`；没有用户 systemd 时检查 `~/.config/autostart/codex-proxy-guardian.desktop`。

安装、修复和卸载都不要使用 `sudo`。

## Codex 反复重启

先确认 Guardian 已升级到 v1.4.2 或更高版本。v1.4.1 及更早版本可能把同一个混合代理端口的 HTTP/SOCKS5 验证波动误判为端点变化；v1.4.2 会保留同一主机与端口上已经验证可用的协议。

1. 立即停止守护任务；此操作不会改变任何网络设置：

   ```powershell
   Stop-ScheduledTask -TaskName 'Codex Proxy Guardian'
   ```

2. 先在开始菜单 **Codex Proxy Guardian Settings** 中选择“自动（Safe）”。如果还要完全关闭普通启动修复，再在安装目录的 `config.json` 中将 `SafeRepairExternalCodexLaunches` 设为 `false`。
3. 检查 `status.json` 和最新的 `logs\guardian-*.jsonl`。重复出现 `proxy_changed` 表示候选端点不稳定；重复出现 `unmanaged_codex` 或 `external_codex_repair` 表示普通 Codex 启动没有带上当前代理参数。
4. 如果自动发现了多个监听器，将 `ExplicitProxy` 设为稳定的 HTTP/混合入站端口。
5. 如果代理软件切换配置时会重建监听器，可适当增加 `DebounceSeconds`、`StableSamples` 或 `RestartCooldownSeconds`。

0.2 及更高版本在 `RestartLimitWindowMinutes` 时间内发生 `RestartLimitCount` 次重启后会停止继续尝试。`Status.ps1` 会显示 `RestartCircuitOpen` 和解除时间。在查清候选端点反复变化的原因前，不要仅仅提高次数上限。

守护程序会匹配当前 Codex 根进程上的 `--proxy-server=<已验证 URI>`，不会依赖启动器 PID 归属，因为 MSIX/Electron 进程交接期间的 PID 关系并不可靠。

## 受控重启后 Codex 一直关闭

0.2 及更高版本会在关闭 Codex 前持久化 `RecoveryLaunchRequired`。如果新进程启动失败，`GuardianState` 会变为 `RecoveringCodex`，代理仍有效时守护程序会在正常频率限制内重试。

从 0.3 起，默认的 Safe 模式会先观察另行启动、但未带代理参数的 Codex：证据等待期内如果发现它已通过当前代理通信，就保持不动；否则进行一次受控修复。只有同时关闭 `SafeRepairExternalCodexLaunches` 和 `ManageExternalCodexLaunches` 时，这类进程才可能使恢复状态变为 `RecoveryBlockedByCodex`；此时请关闭该进程并使用 **Codex (Managed Proxy)**。失败尝试与正常重启共用同一个次数预算；达到上限后 `RestartCircuitOpen` 会阻止无限循环。

## 自动更新失败

运行 `Control.ps1 -Action CheckUpdate` 查看当前通道是否有新版本。更新日志位于安装目录的 `logs\update-*.jsonl`。常见原因包括 GitHub 暂时不可达、Release 资产不完整、SHA-256 不匹配或计划任务缺失；这些情况只会保留当前版本，不会部分覆盖安装。运行新版 `Install.ps1` 可以修复缺失的 `Codex Proxy Guardian Update` 任务。

检查最新日志中的 `codex_started`、`loop_error` 和 `restart_circuit_opened`。不要为了绕过限制直接删除 `state.json`，应先解决启动失败或 MSIX 包路径解析问题。

## 没有选中任何代理

- 确认端点是 HTTP、HTTPS、SOCKS5 或 SOCKS5H；SOCKS4 不支持。
- 确认代理软件开放了 HTTP、SOCKS5 或混合入站端口。
- 确认 Windows 手动代理已启用，或者设置 `ExplicitProxy`。
- 在安装目录运行自检：

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Watch-CodexProxy.ps1 -SelfTest
  ```

退出码 `2` 表示没有候选端点同时通过 TCP 和 HTTPS 验证。端口即使正在监听，也可能无法访问配置的 `ProxyTestUrls`。

运行完整的脱敏诊断：

```powershell
.\Doctor.ps1 -Online
```

默认配置要求至少两个 HTTPS 测试目标成功，可以显著降低“端口存在但代理不可用”的误判概率。

## PAC/WPAD 已启用但没有候选

- Windows 会使用当前用户 WinHTTP 自动代理解析器；确认“使用设置脚本”或“自动检测设置”确实由当前用户启用。
- macOS 检查 `scutil --proxy` 中的 `ProxyAutoConfigURLString` / `ProxyAutoDiscoveryEnable`；GNOME 检查 `gsettings get org.gnome.system.proxy mode` 与 `autoconfig-url`。
- PAC 返回 `SOCKS4`、只有 `DIRECT`，或为不同 OpenAI 验证目标返回互不通用的端点时，Guardian 会保持不接管。
- 企业 PAC 返回远程代理时，确认 `AllowSystemNonLoopbackProxy` 没有被关闭。手写 `ExplicitPAC` 返回远程代理则仍需 `AllowNonLoopbackProxy: true`。
- PAC 下载、DNS 或脚本执行超过安全时限会被拒绝；不要通过无限增大限制掩盖损坏或恶意脚本。

## 显示 ValidatedProxy，但没有 TrafficObserved

`ValidatedProxy` 证明该端点能够承载配置的 HTTPS 验证请求；`LaunchConfigured` 进一步证明当前 Codex 根进程带有相同代理参数；只有实际观察到 Codex 进程树连接该端点后才会出现 `TrafficObserved`。

请在 Codex 中打开或继续一个任务，然后再次查看状态。持续时间很短的连接可能没有被采样到，因此缺少流量证据本身不能直接证明代理无效。

## 找不到 Codex

当前版本支持当前用户安装的 Store/MSIX 包。执行：

```powershell
Get-AppxPackage -Name OpenAI.Codex | Select-Object Name, Version, InstallLocation
```

如果使用兼容但改名的包，请将它的精确包名加入 `CodexPackageNames`。不要仅因为某个第三方包的可执行文件名称相似就加入宽泛匹配。

## 安装被执行策略阻止

`-ExecutionPolicy Bypass` 只影响当前进程策略，不能覆盖 `MachinePolicy` 或 `UserPolicy`。如果安装程序报告组策略限制或 Constrained Language Mode，请联系管理员审核并签名/允许脚本。本项目不应削弱企业安全策略。

## 计划任务注册失败

安装程序会先尝试注册当前用户交互式计划任务，失败后记录 HKCU Run 回退项。运行 `Status.ps1`，并检查 `.cpg-install.json` 中的 `startupMode` 和 `startupError`。如果任务名或 Run 值已被其他程序占用，安装会报错，而不是覆盖不属于本项目的内容。

## 完全回退

```powershell
.\Uninstall.ps1 -KeepLogs -Confirm:$false
```

卸载程序只删除与安装标记匹配的资源。Windows 系统代理、WinHTTP、路由、DNS 和永久环境变量均不会被修改。
