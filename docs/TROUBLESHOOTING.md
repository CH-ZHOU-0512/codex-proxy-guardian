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

## Codex 被意外关闭

v1.8.0 起，Guardian 的公开状态固定为 `CodexRestartPolicy=Never`，代码中没有关闭 Codex 的调用路径。若 Codex 仍然退出，请记录发生时间，并检查 Windows 事件、Codex 自身日志及代理程序日志；这不应由 Guardian 的代理切换触发。

若本机仍安装旧版本，可运行最新版安装器原位升级。升级会保留代理设置，只重启 Guardian 后台任务，不会关闭 Codex。

## 本机代理端口变化后如何在线接续

Windows 会在以下条件同时满足时建立本机 TCP 转发：旧地址和新地址都是回环地址、旧端口已释放、两端同属 HTTP 或 SOCKS5 协议族，并且新端点已经通过真实 HTTPS 验证。成功后 `Status.ps1` 显示 `InPlaceProxyRelayActive=true`。

若显示 `InPlaceRepairPending`，通常是旧端口仍被其他程序占用、当前 Codex 没有可识别的旧显式端点，或新旧协议不兼容。Guardian 不会抢占端口、修改系统代理或重启 Codex；可将代理软件固定为一个稳定的 HTTP/混合入站端口，提高长期命中率。

## 自动更新失败

运行 `Control.ps1 -Action CheckUpdate` 查看当前通道是否有新版本。更新日志位于安装目录的 `logs\update-*.jsonl`。常见原因包括 GitHub 暂时不可达、Release 资产不完整、SHA-256 不匹配或计划任务缺失；这些情况只会保留当前版本，不会部分覆盖安装。运行新版 `Install.ps1` 可以修复缺失的 `Codex Proxy Guardian Update` 任务。

v1.4.4 起，Settings 会区分“更新器正忙，本次没有检查”和“检查完成，没有更高版本”，并显示本机/远端版本、通道与时间。如果界面显示“检查尚未完成”，稍后重试即可，不应把它解释为最新版。

v1.5.2 起，Windows 更新器优先复用 Guardian 已验证的代理：HTTP/HTTPS 使用 PowerShell，SOCKS5/SOCKS5H 使用 Windows 11 自带的 `curl.exe`。`CompatibilityUpdateCheckState=FailedRetryScheduled` 表示本次真实失败但已安排重试，`CompatibilityUpdateRetryAfterUtc` 是下一次时间；`Current` 才表示已经成功访问 GitHub 并确认没有更高版本。若仍停留在 v1.5.1 且更新日志反复出现网络错误，请手动原位安装一次最新正式版，因为需要修复的缺陷就在旧更新器自身。

v1.5.4 起，后台自动更新安装成功后会发送一次系统通知，显示旧版本和新版本，并明确 Codex 无需重启。通知发送结果写入更新日志的 `automatic_update_notification_shown` 或 `automatic_update_notification_failed`；同一版本不会在每次登录时重复提醒。可在 `config.json` 中将 `NotifyAfterAutomaticUpdate` 设为 `false` 关闭此通知。

## Codex 没有被重启，但仍显示正在重新连接

先查看 `Status.ps1`。如果 `InPlaceProxyRelayActive=true`，说明本地端口变化已经在线接续；Codex 日志仍出现 TLS EOF、WebSocket reset、`10054` 或请求超时，通常表示流式连接在代理上游被中断。

v1.5.1 起还要先看 `StreamingProxyGuaranteed`：

- `false` 或 `EffectivenessEvidence=SystemProxyHttpTrafficOnly`：普通启动只证明 HTTP 通过了 Windows 系统代理，不能证明新版 Codex 的 WebSocket/流式子进程继承了显式代理。Guardian 会保持当前 Codex 不动，并在存在兼容旧端点时尝试在线转发。
- `true` 且 `EffectivenessEvidence=ManagedTrafficObserved`：受管启动与实际端点流量都已观察到。若仍重连且没有 Guardian 生命周期事件，再检查代理节点上游。

v1.4.4 默认要求 `chatgpt.com` 关键目标通过；`Status.ps1` 和 `Doctor.ps1` 会显示 `ProxyCriticalTargetsPassed` 与 `ProxyCriticalFailures`。若代理软件日志同时出现上游 `i/o timeout`，请手动换一个稳定节点。

v1.5.0 起，Codex Store/MSIX 包版本变化后，新版进程会进入 `ObservingAfterCodexUpdate`：默认至少 60 秒并累计 3 次新鲜关键入口验证，缓存结果不计数。Guardian 同时立即启动经过安装所有权校验的更新任务；观察期间一次本地代理流量不会被 Safe 模式过早当成稳定结论。

若 `GuardianState=UpstreamSuspected`，表示本地代理监听仍可达、但关键外部验证失败。Guardian 会保留当前 Codex，不会因此重启应用、切换代理软件里的订阅节点或修改系统代理。保持 Codex 打开；若重连持续，请在 Clash/Mihomo/v2rayN 等代理软件中换节点。一次新的关键入口验证通过后，该状态会自动清除。

`StreamStability=IndirectEvidenceOnly` 不是报错。它是在说明短 HTTPS 探测与本地 TCP 元数据无法从外部证明登录态下的长时 SSE/HTTP 流绝对稳定。

若出现 `CodexCompatibilityReviewRequired`，表示用户已批准的一次 Managed 启动在超时后仍没有得到参数或流量证据。为避免反复关闭任务，Guardian 已停止该 Codex/Guardian 组合的自动生命周期操作；当前 Codex 会保持打开。即时更新检查与每日更新仍会自动运行，新 Guardian 版本安装后会清除旧保持并重新审计。

检查最新日志中的 `proxy_relay_started`、`proxy_relay_unavailable`、`proxy_upstream_suspected` 和 `loop_error`。不要直接删除 `state.json`；它保存已验证端点与在线转发目标。

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

## 显示 ValidatedProxy，但没有 ManagedTrafficObserved

`ValidatedProxy` 证明该端点能够承载配置的 HTTPS 验证请求；`LaunchConfigured` 进一步证明当前 Codex 根进程带有相同代理参数；只有受管启动后又实际观察到 Codex 进程树连接该端点，才会出现 `ManagedTrafficObserved`。`SystemProxyHttpTrafficOnly` 只证明普通启动的 HTTP 流量经过代理，不再被当成流式代理完整生效。

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
