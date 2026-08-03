# 故障排查

[简体中文](TROUBLESHOOTING.md) | [English](TROUBLESHOOTING.en.md)

## Codex 反复重启

1. 立即停止守护任务；此操作不会改变任何网络设置：

   ```powershell
   Stop-ScheduledTask -TaskName 'Codex Proxy Guardian'
   ```

2. 在安装目录的 `config.json` 中，将 `Mode` 设为 `Safe`，将 `ManageExternalCodexLaunches` 设为 `false`。
3. 检查 `status.json` 和最新的 `logs\guardian-*.jsonl`。重复出现 `proxy_changed` 表示候选端点不稳定；重复出现 `unmanaged_codex` 表示 Enforce 模式没有在 Codex 根进程上观察到预期启动参数。
4. 如果自动发现了多个监听器，将 `ExplicitProxy` 设为稳定的 HTTP/混合入站端口。
5. 如果代理软件切换配置时会重建监听器，可适当增加 `DebounceSeconds`、`StableSamples` 或 `RestartCooldownSeconds`。

0.2 及更高版本在 `RestartLimitWindowMinutes` 时间内发生 `RestartLimitCount` 次重启后会停止继续尝试。`Status.ps1` 会显示 `RestartCircuitOpen` 和解除时间。在查清候选端点反复变化的原因前，不要仅仅提高次数上限。

守护程序会匹配当前 Codex 根进程上的 `--proxy-server=<已验证 URI>`，不会依赖启动器 PID 归属，因为 MSIX/Electron 进程交接期间的 PID 关系并不可靠。

## 受控重启后 Codex 一直关闭

0.2 及更高版本会在关闭 Codex 前持久化 `RecoveryLaunchRequired`。如果新进程启动失败，`GuardianState` 会变为 `RecoveringCodex`，代理仍有效时守护程序会在正常频率限制内重试。

如果另行启动、但未带代理参数的 Codex 阻止 Safe 模式恢复，状态会变为 `RecoveryBlockedByCodex`；请关闭该进程并使用 **Codex (Managed Proxy)**。失败尝试与正常重启共用同一个次数预算；达到上限后 `RestartCircuitOpen` 会阻止无限循环。

检查最新日志中的 `codex_started`、`loop_error` 和 `restart_circuit_opened`。不要为了绕过限制直接删除 `state.json`，应先解决启动失败或 MSIX 包路径解析问题。

## 没有选中任何代理

- 确认端点是 HTTP 或 HTTPS，而不是仅 SOCKS。
- 确认代理软件开放了 HTTP 或混合入站端口。
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
