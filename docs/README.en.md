# Codex Proxy Guardian for Windows

[简体中文](../README.md) | [English](README.en.md)

An unofficial, current-user watchdog for the Store/MSIX Codex desktop app on Windows 11. It validates an HTTP/HTTPS proxy against multiple OpenAI/ChatGPT HTTPS targets, launches Codex with process-scoped proxy variables and a Chromium proxy argument, and relaunches Codex only after a stable proxy endpoint change.

## Why this exists

Many Windows proxy applications expose a local HTTP endpoint such as `127.0.0.1:7890`. Other applications must connect to that endpoint to use the proxy. A working browser does not necessarily mean that an already-running Codex process received the same proxy configuration. When the proxy application restarts, changes profiles, or updates, its port may change while Codex keeps using the old address, resulting in sign-in failures, content that does not load, or interrupted tasks.

The manual workaround is to find the current port, close Codex, set proxy environment variables or launch arguments, and start Codex again—then repeat whenever the endpoint changes. Codex Proxy Guardian automates that sequence: it discovers candidates, proves that the proxy can carry real HTTPS requests, applies only a stable change, and uses debounce, cooldown, and a circuit breaker to avoid restart loops. The default `Safe` mode is intended to work without requiring users to understand ports, environment variables, or Task Scheduler.

> [!NOTE]
> This project is **not a proxy application and does not provide a proxy service or endpoints**. A working HTTP/HTTPS proxy must already exist on the computer. The guardian solves the narrower problem of keeping Codex aligned with that proxy.

> [!IMPORTANT]
> This is an independent community project. It is not affiliated with, endorsed by, or supported by OpenAI. The proxy behavior used here is a best-effort compatibility technique, not a documented Codex desktop API.

## Safety first

- It never changes Windows system proxy, WinHTTP proxy, DNS, routes, or persistent user/machine environment variables.
- It accepts only HTTP/HTTPS proxy endpoints with explicit ports. Credentials embedded in proxy URLs are rejected.
- A candidate must have a live TCP listener and pass an HTTPS request through the proxy before it can become active.
- Changes are debounced, restarts have a cooldown, and one mutex is used per installation.
- A restart-rate circuit breaker opens after three restarts in ten minutes by default, preventing an unstable environment from relaunching Codex indefinitely.
- Before a managed restart, recovery intent is persisted. If the new Codex process does not start, the guardian retries within the same rate limit instead of silently leaving Codex closed.
- Candidate ordering is deterministic and keeps the current endpoint within the same priority tier, avoiding port flip-flop.
- The MSIX manifest is periodically re-read, so a Store update can move the executable without leaving the guardian on a stale version path.
- Uninstall removes only resources whose installation marker and target paths match.
- `Safe` is the default mode. It reacts to a validated proxy endpoint change but does not take over every normally launched Codex process.

## Supported baseline

- Windows 11, interactive current-user session
- Windows PowerShell 5.1 or PowerShell 7 for setup; the background task uses Windows PowerShell 5.1
- Codex installed from Microsoft Store or an enterprise-distributed Store-signed MSIX
- Explicit Windows Internet Settings proxy (`ProxyEnable` + `ProxyServer`)
- A manually configured HTTP/HTTPS endpoint
- Inherited `HTTPS_PROXY`, `HTTP_PROXY`, or HTTP-compatible `ALL_PROXY` values
- Loopback listeners owned by common Clash/Mihomo, V2Ray/Xray, sing-box, Shadowsocks, NekoRay, Hiddify, or FlClash processes
- x64 and ARM64, resolved from the installed package manifest rather than a hard-coded path

PAC/WPAD, pure SOCKS proxies, TUN-only configurations, WinHTTP-only proxy settings, services running in another user session, and enforced script restrictions are not automatically supported. See the [support matrix](SUPPORT.en.md).

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

The earlier restart-loop class is avoided by matching the root process's proxy argument, not a short-lived launcher PID. Explicitly opening **Codex (Managed Proxy)** replaces an already-running Codex only when its root is missing the validated proxy argument, and the same cooldown/circuit protection still applies.

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

`ExplicitProxy` has the highest priority. Leave it empty to inspect the current Windows proxy and recognized proxy-process listeners. See [default-config.json](../config/default-config.json) and [config.schema.json](../config/config.schema.json).

## Status and logs

```powershell
.\Status.ps1
.\Status.ps1 -Json
.\Doctor.ps1 -Online
```

The status reports progressive effectiveness evidence:

| Evidence | Meaning |
|---|---|
| `ValidatedProxy` | The endpoint accepted a TCP connection and met the configured HTTPS-test quorum |
| `LaunchConfigured` | A current Codex root also carries the same normalized proxy argument |
| `TrafficObserved` | A Codex process-tree connection to that proxy endpoint was observed recently |

`TrafficObserved` is the strongest local evidence this project can provide without packet capture. It does not claim a particular exit IP, location, anonymity level, or proxy policy. Run `Doctor.ps1 -Online -Json` to create a deliberately redacted compatibility report; it omits raw proxy URLs, user paths, and logs.

`GuardianState` distinguishes `Stabilizing`, `Ready`, `WaitingForProxy`, `RecoveringCodex`, `RecoveryBlockedByCodex`, and `RestartCircuitOpen`. `Control.ps1 -Action Start` waits through the normal debounce phase and reports the resulting state.

Control the guardian itself without touching Codex or Windows networking:

```powershell
.\Control.ps1 -Action Restart
.\Control.ps1 -Action Stop
.\Control.ps1 -Action Start
```

Runtime status is in `status.json`; daily JSON Lines logs are under `logs`. Logs rotate by size, age, and count. Proxy credentials are never accepted or logged.

If Codex starts restarting unexpectedly, the circuit breaker will stop further relaunches. Keep Safe mode enabled and follow [Troubleshooting](TROUBLESHOOTING.en.md).

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

The release tool runs tests, creates a ZIP in `artifacts`, and writes a SHA-256 checksum. Store/MSIX integration tests require a real Windows user session and are intentionally separate from CI. See [compatibility and effectiveness testing](COMPATIBILITY-TESTING.md) for the online proof and soak-test gates.

Architecture and threat boundaries are documented in [ARCHITECTURE.md](ARCHITECTURE.md).

## License

[MIT](../LICENSE). “Codex” and “OpenAI” may be trademarks of their respective owners; see [DISCLAIMER.md](../DISCLAIMER.md).
