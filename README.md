# Codex Proxy Guardian for Windows

An unofficial, current-user watchdog for the Store/MSIX Codex desktop app on Windows 11. It validates an HTTP/HTTPS proxy, launches Codex with process-scoped proxy variables and a Chromium proxy argument, and relaunches Codex only after a stable proxy endpoint change.

> [!IMPORTANT]
> This is an independent community project. It is not affiliated with, endorsed by, or supported by OpenAI. The proxy behavior used here is a best-effort compatibility technique, not a documented Codex desktop API.

## Safety first

- It never changes Windows system proxy, WinHTTP proxy, DNS, routes, or persistent user/machine environment variables.
- It accepts only HTTP/HTTPS proxy endpoints with explicit ports. Credentials embedded in proxy URLs are rejected.
- A candidate must have a live TCP listener and pass an HTTPS request through the proxy before it can become active.
- Changes are debounced, restarts have a cooldown, and one mutex is used per installation.
- Uninstall removes only resources whose installation marker and target paths match.
- `Safe` is the default mode. It reacts to a validated proxy endpoint change but does not take over every normally launched Codex process.

## Supported baseline

- Windows 11, interactive current-user session
- Windows PowerShell 5.1 or PowerShell 7 for setup; the background task uses Windows PowerShell 5.1
- Codex installed from Microsoft Store or an enterprise-distributed Store-signed MSIX
- Explicit Windows Internet Settings proxy (`ProxyEnable` + `ProxyServer`)
- A manually configured HTTP/HTTPS endpoint
- Loopback listeners owned by common Clash/Mihomo, V2Ray/Xray, sing-box, Shadowsocks, NekoRay, Hiddify, or FlClash processes
- x64 and ARM64, resolved from the installed package manifest rather than a hard-coded path

PAC/WPAD, pure SOCKS proxies, TUN-only configurations, WinHTTP-only proxy settings, services running in another user session, and enforced script restrictions are not automatically supported. See [support matrix](docs/SUPPORT.md).

## Install

Download and extract a release ZIP. In a normal, non-administrator PowerShell window:

```powershell
Unblock-File .\Install.ps1
.\Install.ps1
```

If your local execution policy does not allow direct invocation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The default installation is `%LOCALAPPDATA%\CodexProxyGuardian`. Setup creates a current-user scheduled task and a Start Menu shortcut named **Codex (Managed Proxy)**. If Task Scheduler registration is unavailable, it falls back to the current user's `Run` key.

Setup checks connectivity but treats a temporarily offline proxy as a warning. Use `-RequireConnectivity` to make that check mandatory:

```powershell
.\Install.ps1 -RequireConnectivity
```

To stage on a machine without Codex installed:

```powershell
.\Install.ps1 -AllowMissingCodex -NoStart
```

## Modes

| Mode | Behavior | Recommendation |
|---|---|---|
| `Safe` | Restarts Codex after a validated endpoint change; ordinary external launches are not forcibly replaced | Default for public installs |
| `Enforce` | Also detects a Codex root process missing the current proxy argument and relaunches it after debounce | Opt in after Safe mode is proven stable |

Enable Enforce mode during installation or update:

```powershell
.\Install.ps1 -Mode Enforce
```

The earlier restart-loop class is avoided by matching the root process's proxy argument, not a short-lived launcher PID.

## Configuration

Edit `%LOCALAPPDATA%\CodexProxyGuardian\config.json`, then restart the scheduled task. Common options:

```json
{
  "ExplicitProxy": "http://127.0.0.1:7890",
  "AllowNonLoopbackProxy": false,
  "ManageExternalCodexLaunches": false,
  "DebounceSeconds": 10,
  "RestartCooldownSeconds": 45
}
```

`ExplicitProxy` has the highest priority. Leave it empty to inspect the current Windows proxy and recognized proxy-process listeners. See [default-config.json](config/default-config.json) and [config.schema.json](config/config.schema.json).

## Status and logs

```powershell
.\Status.ps1
.\Status.ps1 -Json
```

Runtime status is in `status.json`; daily JSON Lines logs are under `logs`. Logs rotate by size, age, and count. Proxy credentials are never accepted or logged.

If Codex starts restarting unexpectedly, switch to Safe mode first and follow [Troubleshooting](docs/TROUBLESHOOTING.md).

## Uninstall

From the release directory or installed directory:

```powershell
.\Uninstall.ps1 -Confirm:$false
```

To preserve logs outside the installation directory:

```powershell
.\Uninstall.ps1 -KeepLogs -Confirm:$false
```

Uninstall does not restore network settings because the project never modifies them.

## Build and test

```powershell
.\tests\Run-Tests.ps1
.\tools\Package-Release.ps1
```

The release tool runs tests, creates a ZIP in `artifacts`, and writes a SHA-256 checksum. Store/MSIX integration tests require a real Windows user session and are intentionally separate from CI.

中文说明见 [docs/README.zh-CN.md](docs/README.zh-CN.md). Architecture and threat boundaries are documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License

[MIT](LICENSE). “Codex” and “OpenAI” may be trademarks of their respective owner; see [DISCLAIMER.md](DISCLAIMER.md).
