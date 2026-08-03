# Codex Proxy Guardian for Windows

[简体中文](../README.md) | [English](README.en.md)

![Codex Proxy Guardian social preview](../assets/social-preview.png)

> **In one sentence:** If Codex often reconnects four or five times before it starts thinking because it did not pick up the working proxy, this tool is designed to fix that.

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
- Automatic (`Safe`) is the default mode. For a normally launched Codex process missing the current proxy argument, it waits for traffic evidence before performing one controlled repair; a process already observed using the validated proxy is left untouched.
- A daily current-user task checks this project's GitHub Releases and installs an update only after tag, filename, staged `VERSION`, and SHA-256 checks agree.
- A single-file graphical installer lets normal users install or upgrade without administrator rights.

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

### Recommended: one-click EXE

1. Open the [latest stable Release](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases/latest) and download the `.exe` whose name starts with `CodexProxyGuardian-Setup-`.
2. Double-click it and confirm that the window links to `CH-ZHOU-0512/codex-proxy-guardian`.
3. Select **Install now**. Guardian starts in the background when setup completes; keep opening Codex normally afterward.

The installer is current-user only, does not request elevation, and does not change the Windows system proxy, WinHTTP, DNS, routes, or persistent environment variables. It embeds the exact ZIP produced by the same Release build and validates its version and required files before installation.

> [!WARNING]
> This community project does not currently have a commercial code-signing certificate, so Windows SmartScreen may show an unrecognized-app warning. Download only from this repository's official Releases. Use the ZIP method below if the source cannot be confirmed or your policy blocks unsigned software; do not disable Windows security features.

For an optional integrity check, download the matching `.sha256` file and compare these outputs:

```powershell
Get-FileHash .\CodexProxyGuardian-Setup-*.exe -Algorithm SHA256
Get-Content .\CodexProxyGuardian-Setup-*.exe.sha256
```

### Alternative: release ZIP

Download the versioned ZIP and its `.sha256` from the same Release, extract it, and run the following in a normal, non-administrator PowerShell window. Do not use GitHub's automatically generated `Source code` archives.

```powershell
Unblock-File .\Install.ps1
.\Install.ps1
```

If your local execution policy does not allow direct invocation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The default installation is `%LOCALAPPDATA%\CodexProxyGuardian`. Setup creates the guardian and update tasks, a **Codex (Managed Proxy)** shortcut, and a **Codex Proxy Guardian Settings** shortcut. The settings window switches mode, automatic updates, and update channel without editing JSON. If guardian Task Scheduler registration is unavailable, startup falls back to the current user's `Run` key.

Setup checks connectivity but treats a temporarily offline proxy as a warning. Use `-RequireConnectivity` to make that check mandatory:

```powershell
.\Install.ps1 -RequireConnectivity
```

To stage on a machine without Codex installed:

```powershell
.\Install.ps1 -AllowMissingCodex -NoStart
```

## Automatic and Strict modes

| User profile | Internal mode | Behavior | Recommendation |
|---|---|---|---|
| Automatic | `Safe` | Waits 20 seconds for proxy-traffic evidence; leaves a working process alone or performs one controlled repair | Default for public installs |
| Strict | `Enforce` | Repairs a missing proxy argument after debounce, without the Safe traffic-evidence exemption | Opt in when exact launch arguments must be enforced |

Use the Start Menu settings window, or switch with one command:

```powershell
.\Control.ps1 -Action SetMode -Mode Auto
.\Control.ps1 -Action SetMode -Mode Strict
.\Control.ps1 -Action ToggleMode
```

The earlier restart-loop class is avoided by matching the root process's proxy argument, not a short-lived launcher PID. In short, Automatic means “prove a repair is needed first,” while Strict means “repair any argument mismatch.” The program does not silently change a user's long-term profile from Automatic to Strict; the automatic decision is made per Codex launch from traffic evidence. Mode changes are reloaded by the guardian in the background without restarting Guardian or the current Codex process. Explicitly opening **Codex (Managed Proxy)** remains the immediate deterministic path, and the same cooldown/circuit protection applies to every repair. During a Store update, an existing Codex process is left running if the replacement MSIX executable cannot yet be resolved.

## Configuration

Edit `%LOCALAPPDATA%\CodexProxyGuardian\config.json`, then restart the scheduled task. Common options:

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

`ExplicitProxy` has the highest priority. Leave it empty to inspect the current Windows proxy and recognized proxy-process listeners. See [default-config.json](../config/default-config.json) and [config.schema.json](../config/config.schema.json).

## Automatic updates

The daily updater is bound to `CH-ZHOU-0512/codex-proxy-guardian`. It requires the Release tag, archive name, staged `VERSION`, attached `.sha256`, and the GitHub asset digest when available to agree before invoking the installer. It rejects unsafe archive paths and extraction limits, snapshots the current files, and attempts to restore the previous version and guardian after an interrupted install. Results are written to `logs\update-*.jsonl`.

```powershell
.\Control.ps1 -Action CheckUpdate
.\Control.ps1 -Action Update
```

New installations default to the `Stable` channel. Users who deliberately want early Alpha/Beta builds can opt into `Prerelease` in Settings. An in-place update preserves the existing channel and other configuration, then asks the guardian to adopt the current Codex session.

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
.\Control.ps1 -Action SetMode -Mode Auto
.\Control.ps1 -Action CheckUpdate
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
