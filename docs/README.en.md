# Codex Proxy Guardian for Windows, macOS, and Linux

[简体中文](../README.md) | [English](README.en.md)

![Codex Proxy Guardian social preview](../assets/social-preview.png)

> **In one sentence:** This tool reduces reconnects caused by Codex missing the working proxy or keeping a stale endpoint.

An unofficial current-user watchdog that validates changing HTTP, HTTPS, or SOCKS5 proxies—and the effective routes selected by PAC/WPAD—against multiple OpenAI/ChatGPT targets before applying them to Codex.

| Platform | Protected target | Normal use after setup |
|---|---|---|
| Windows 11 | Store/MSIX Codex desktop | Open Codex normally; compatible local port changes are repaired in place |
| macOS (Intel / Apple Silicon) | ChatGPT/Codex desktop app | Open the app normally; the current app is never restarted |
| Linux (x64 / ARM64) | Official Codex CLI | Start with `codex-guard`; interactive terminal sessions are never killed or restarted |

## Why this exists

Many proxy applications expose a local HTTP endpoint such as `127.0.0.1:7890`. A working browser does not necessarily mean that an already-running Codex process received the same endpoint. When the proxy application restarts, changes profiles, or updates, its port may change while Codex keeps using the old address, resulting in sign-in failures, content that does not load, or interrupted tasks.

Codex Proxy Guardian discovers candidates, proves that the proxy can carry real HTTPS requests, and applies only a stable change. On Windows, a released old loopback port can be forwarded to the newly validated endpoint so the existing Codex process stays open. The default `Safe` mode is intended to work without requiring users to understand ports, environment variables, or Task Scheduler.

> [!NOTE]
> This project is **not a proxy application and does not provide a proxy service or endpoints**. A working HTTP, HTTPS, or SOCKS5 endpoint—or PAC/WPAD that selects one for OpenAI targets—must already exist on the computer.

> [!IMPORTANT]
> **Guardian never closes or restarts Codex.** It manages proxy discovery, validation, reconnect monitoring, and compatible local endpoint forwarding. It cannot repair packet loss, TLS EOF, WebSocket resets, Windows `10054`, or request timeouts inside a proxy-provider node.

> [!TIP]
> **v1.8.1 repairs first-request proxy routing.** With a validated Windows system proxy, Guardian checks whether the actual Codex CLI supports `respect_system_proxy` and enables it for new sessions while preserving the built-in OpenAI provider and Dot. It backs up config and respects an explicit opt-out. The feature is currently under development in Codex, so support is detected at runtime.
>
> **v1.8.0 makes `CodexRestartPolicy=Never` a hard rule.** When a Windows loopback proxy port changes, Guardian binds the released old port and forwards compatible HTTP-family or SOCKS5-family TCP streams to the validated endpoint. A failed bind or incompatible protocol leaves Codex untouched and is reported as `InPlaceRepairPending`.
>
> Codex `26.1021.3705.0` moved app-server connection evidence into `logs_2.sqlite`. Guardian queries committed records read-only through Windows' built-in SQLite engine, including after WAL reuse, and recognizes `stream disconnected - retrying sampling request (n/5)`, remote-control WebSocket retries, and local IPC failures. Task content is not collected.
>
> **v1.5.4 reports a successful automatic update to the signed-in user.** The one-time notification shows the previous and installed versions, states that Codex does not need to restart, requires no confirmation, and is not repeated at every login. Windows, macOS, and common Linux desktop notification systems are covered.
>
>
> **v1.5.2 fixes an update chain that could start the scheduled task but never confirm that the check actually completed.** The updater reuses Guardian's validated HTTP/HTTPS/SOCKS route, records the terminal result, and retries failures for the same Codex version. “Current” now means GitHub was reached successfully.

## Attributing a reconnect

| Evidence at the same timestamp | More likely cause | Next action |
|---|---|---|
| `InPlaceProxyRelayActive=true` | The old local endpoint is forwarding to the validated endpoint | No action is needed |
| Neither event exists; Codex logged TLS EOF, WebSocket reset, `10054`, or timeout | The selected provider node or its upstream path dropped the stream | Select a healthier node in the proxy application |
| `ProxyCriticalTargetsPassed=false` | The critical `chatgpt.com` entry point did not validate | Inspect `ProxyCriticalFailures` and the provider node |
| `GuardianState=ObservingAfterCodexUpdate` | A newly updated Codex is accumulating fresh validation samples | Keep Codex open and let the observation finish |
| `GuardianState=UpstreamSuspected` | The local listener works, but critical external validation failed | Keep Codex open and select a healthier provider node |
| `StreamingProxyGuaranteed=false` | HTTP may use the system proxy, but the streaming process has no managed-launch evidence | Finish the task, then approve the prompt or open **Codex (Managed Proxy)** |
| `GuardianState=CodexCompatibilityReviewRequired` | Launch adaptation for the new version could not be confirmed and is safely held | Keep Codex open; Guardian checks verified adapter updates automatically |

Guardian may try another discovered and validated endpoint or protocol. It never silently switches subscription nodes inside Clash/Mihomo/v2rayN, and it never changes system network settings.

> [!IMPORTANT]
> This is an independent community project. It is not affiliated with, endorsed by, or supported by OpenAI. The proxy behavior used here is a best-effort compatibility technique, not a documented Codex desktop API.

## Safety first

- It never changes system proxy, WinHTTP proxy, DNS, routes, firewall rules, or persistent user/machine environment variables.
- It accepts HTTP, HTTPS, SOCKS5, and SOCKS5H endpoints with explicit ports. SOCKS4 and credential-bearing URLs are rejected.
- Windows delegates PAC/WPAD policy to WinHTTP. The macOS/Linux PAC runtime separately bounds source size, fetches, DNS helpers, JavaScript execution, and cache lifetime. WPAD is used only when the OS has auto-discovery enabled.
- A candidate must have a live TCP listener and pass an HTTPS request through the proxy before it can become active.
- Changes are debounced, and one mutex is used per installation.
- Windows in-place forwarding is restricted to loopback endpoints in a compatible protocol family.
- Relay ownership uses both a PID and random instance token before a child process can be stopped.
- Candidate ordering is deterministic and keeps the current endpoint within the same priority tier, avoiding port flip-flop.
- The MSIX manifest is periodically re-read. When a Store update moves the executable, Guardian waits for the new process and requires consecutive fresh critical-target validations before accepting Safe-mode traffic evidence.
- Uninstall removes only resources whose installation marker and target paths match.
- Automatic (`Safe`) is the default mode. For a normally launched Codex process missing the current proxy argument, it validates traffic and keeps the process open. On Windows, a compatible old loopback endpoint can be preserved by the in-place relay after the proxy port changes.
- A daily current-user task checks this project's GitHub Releases and installs an update only after tag, filename, staged `VERSION`, and SHA-256 checks agree.
- A single-file graphical installer lets normal users install or upgrade without administrator rights.

## Supported baseline

| Area | Windows 11 | macOS | Linux |
|---|---|---|---|
| Architectures | x64, ARM64 | Intel, Apple Silicon | x64, ARM64 |
| Codex target | Store/MSIX desktop | ChatGPT/Codex desktop | Official Codex CLI |
| System discovery | Internet Settings | `scutil --proxy` | GNOME `gsettings`; use explicit config elsewhere |
| Current-user startup | Scheduled Task / HKCU Run | LaunchAgent | systemd user / XDG Autostart |
| Lifecycle action | In-place local relay; no Codex restart | Keeps the current app open | No CLI restart |

All platforms support explicit HTTP/HTTPS/SOCKS5 endpoints, inherited `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`, system PAC/WPAD, and recognized loopback listeners. PAC directives are evaluated for the configured OpenAI targets; a resolved endpoint must still pass the normal multi-target quorum. Mutually incompatible per-target routes safely produce no takeover. SOCKS4, credential-bearing URLs, and TUN-only configurations with no discoverable endpoint remain unsupported. See the [support matrix](SUPPORT.en.md).

> [!IMPORTANT]
> OpenAI currently provides desktop apps for macOS/Windows and the Codex CLI for Linux. There is no official Linux Codex desktop app, so the Linux edition deliberately wraps the CLI instead of claiming desktop support. See the official [Codex app](https://learn.chatgpt.com/docs/app) and [Codex CLI quickstart](https://learn.chatgpt.com/docs/quickstart).

## Install

### macOS

Download the matching stable Release asset:

- Apple Silicon: `CodexProxyGuardian-VERSION-darwin-arm64.tar.gz`
- Intel: `CodexProxyGuardian-VERSION-darwin-amd64.tar.gz`

Extract it, enter the `CodexProxyGuardian` directory, and run as your normal user:

```sh
./install.sh
codex-proxy-guardian doctor
```

The installer copies the binary under `~/.local/lib`, registers a current-user LaunchAgent, and starts it silently. Keep opening ChatGPT/Codex normally.

### Linux

Download `linux-amd64.tar.gz` or `linux-arm64.tar.gz`, extract it, then run:

```sh
./install.sh
codex-proxy-guardian doctor
codex-guard
```

Setup prefers a systemd user service and falls back to XDG Autostart. Do not use `sudo`. `codex-guard` obtains the last validated proxy and replaces itself with the official Codex CLI while preserving the terminal and all arguments, for example `codex-guard resume --last`.

Running plain `codex` still depends on that shell's environment: a guardian cannot retroactively edit another terminal process. Use `codex-guard` when the validated endpoint must be applied. Linux terminal sessions are never killed or restarted automatically.

### Windows 11: recommended one-click EXE

1. Open the [latest stable Release](https://github.com/CH-ZHOU-0512/codex-proxy-guardian/releases/latest) and download the `.exe` whose name starts with `CodexProxyGuardian-Setup-`.
2. Double-click it and confirm that the window links to `CH-ZHOU-0512/codex-proxy-guardian`.
3. Select **Install now**. Guardian starts in the background when setup completes; keep opening Codex normally afterward.

The installer is current-user only, does not request elevation, and does not change the Windows system proxy, WinHTTP, DNS, routes, or persistent environment variables. It embeds the exact ZIP produced by the same Release build and validates its version and required files before installation. During setup, the window shows the current stage and determinate 0–100% progress instead of an indefinite spinner.

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

The default installation is `%LOCALAPPDATA%\CodexProxyGuardian`. Setup creates the guardian and update tasks, a **Codex (Managed Proxy)** shortcut, and a **Codex Proxy Guardian Settings** shortcut. The managed shortcut is the deterministic Windows entry point: it injects process-scoped HTTP/HTTPS/ALL/WS/WSS proxy variables plus the Chromium proxy argument. Ordinary Codex launches remain supported, but Guardian asks before replacing one when only system-proxy HTTP evidence is present. The settings window switches mode, automatic updates, and update channel without editing JSON. If guardian Task Scheduler registration is unavailable, startup falls back to the current user's `Run` key.

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
| Automatic | `Safe` | Distinguishes system-proxy HTTP traffic from a managed streaming launch, then prompts before repair; after a Codex update it also requires consecutive fresh critical-target checks | Default for public installs |
| Strict | `Enforce` | Repairs a missing proxy argument after debounce, without the Safe traffic-evidence exemption | Opt in when exact launch arguments must be enforced |

Use the Start Menu settings window, or switch with one command:

```powershell
.\Control.ps1 -Action SetMode -Mode Auto
.\Control.ps1 -Action SetMode -Mode Strict
.\Control.ps1 -Action ToggleMode
```

On macOS/Linux:

```sh
codex-proxy-guardian mode auto
codex-proxy-guardian mode strict
```

HTTP/SOCKS5 variants on one host and port are treated as the same lifecycle endpoint. A genuinely different Windows loopback endpoint is handled by a compatible in-place TCP relay when the old port is available. Automatic uses the normal evidence window; Strict shortens the observation before attempting the same non-disruptive repair. Neither mode closes Codex. Mode changes reload Guardian in the background without restarting the current Codex process.

## Configuration

Configuration locations are `%LOCALAPPDATA%\CodexProxyGuardian\config.json` on Windows, `~/Library/Application Support/CodexProxyGuardian/config.json` on macOS, and `${XDG_CONFIG_HOME:-~/.config}/codex-proxy-guardian/config.json` on Linux.

Common options:

```json
{
  "ExplicitProxy": "http://127.0.0.1:7890",
  "ExplicitPAC": "",
  "AutomaticUpdates": true,
  "NotifyAfterAutomaticUpdate": true,
  "UpdateChannel": "Stable",
  "AllowNonLoopbackProxy": false,
  "AllowSystemNonLoopbackProxy": true,
  "ManageExternalCodexLaunches": false,
  "SafeRepairExternalCodexLaunches": true,
  "EnableInPlaceProxyRelay": true,
  "RequireManagedLaunchForStreaming": true,
  "SafeExternalLaunchGraceSeconds": 20,
  "DebounceSeconds": 10
}
```

`ExplicitProxy` accepts `http://`, `https://`, `socks5://`, or `socks5h://`. `ExplicitPAC` accepts an absolute HTTP/HTTPS PAC URL; macOS/Linux also accept local `file://` PAC. Leave both empty to inspect the platform proxy/PAC/WPAD, inherited variables, and recognized listeners. See the Windows [default-config.json](../config/default-config.json), its [config.schema.json](../config/config.schema.json), and the [macOS/Linux defaults](../config/default-posix-config.json).

## Automatic updates

The daily updater is bound to `CH-ZHOU-0512/codex-proxy-guardian`. It requires the Release tag, archive name, staged `VERSION`, attached `.sha256`, and the GitHub asset digest when available to agree before invoking the installer. It rejects unsafe archive paths and extraction limits, snapshots the current files, and attempts to restore the previous version and guardian after an interrupted install. Results are written to `logs\update-*.jsonl`.

Starting with v1.5.2, Windows prefers Guardian's currently validated proxy for GitHub requests. PowerShell handles HTTP/HTTPS and Windows 11 `curl.exe` handles SOCKS5/SOCKS5H; bounded retries fall back to the Windows default route without changing system networking or persistent environment variables. A Codex-triggered check reports `Running`, `Current`, `Installed`, or `FailedRetryScheduled`, and a failed check is retried for that same Codex version instead of being permanently marked requested. New installs default to a 15-minute compatibility retry interval.

Starting with v1.4.4, **Check now** distinguishes a busy/skipped check from a completed current result and displays the installed version, remote version, selected channel, check time, and GitHub Releases source. It checks the channel currently selected in the UI even before the setting is applied.

Windows validation also requires the critical `chatgpt.com` target to pass. Two unrelated successful probes can no longer hide a failed streaming entry point. Guardian can detect this condition and try another discovered candidate, but it cannot repair packet loss or WebSocket resets inside the user's selected proxy-provider node without changing network policy.

On macOS/Linux the daemon selects only the `.tar.gz` for the current OS and architecture, checks the tag, semantic version, filename, staged `VERSION`, SHA-256, entry types, extraction size, and paths, then atomically replaces and executes the new binary. A failed update keeps the current binary or its `.previous` backup.

```powershell
.\Control.ps1 -Action CheckUpdate
.\Control.ps1 -Action Update
```

```sh
codex-proxy-guardian update
codex-proxy-guardian update --install
```

New installations default to the `Stable` channel. Users who deliberately want early Alpha/Beta builds can opt into `Prerelease` in Settings. An in-place update preserves the existing channel and other configuration, then asks the guardian to adopt the current Codex session.

## Status and logs

macOS/Linux:

```sh
codex-proxy-guardian status
codex-proxy-guardian status --json
codex-proxy-guardian doctor
```

Windows:

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
| `SystemProxyHttpTrafficOnly` | An ordinary Codex process used the Windows system proxy; this does not prove explicit WebSocket proxy inheritance |
| `ManagedTrafficObserved` | Managed launch configuration matched and a Codex process-tree connection to that endpoint was observed |
| `TrafficObserved` | macOS/Linux observed a Codex process-tree connection; Windows v1.5.1 reports one of the two more precise states above |
| `PostUpdateObservation` | A newly updated Codex is accumulating fresh critical-target validations; one local connection is not yet accepted as stable |
| `EndpointReachableOnly` | The local listener works but a critical external validation failed; Codex is kept open |

`ManagedTrafficObserved` is the strongest local evidence this project can provide without packet capture. Short HTTPS probes and local TCP metadata still cannot prove that an authenticated, long-lived Codex stream will remain stable, so the normal status deliberately says `StreamStability=IndirectEvidenceOnly`. It does not claim a particular exit IP, location, anonymity level, or proxy policy. Run `Doctor.ps1 -Online -Json` to create a deliberately redacted compatibility report; it omits raw proxy URLs, user paths, and logs.

For every detected Codex package version, Guardian re-resolves the MSIX manifest and real root executable, records a capability fingerprint, runs the post-update audit, and starts the repository's verified Release updater immediately. A still-compatible generic adapter continues automatically. If Codex changes an undocumented launch mechanism, Guardian cannot invent unknown upstream behavior; it fails safe, leaves Codex open, and adopts a compatible Guardian release automatically when one becomes available.

### Compatibility contract for every future Codex version

This is behavior-based rather than a whitelist of known version numbers. Every Codex package version change invalidates previous evidence, re-resolves the manifest entry point, and requires fresh critical-target validation. On Windows, compatibility additionally requires both matching managed-launch configuration and fresh proxy traffic from the new process. A failure enters a no-restart safety hold and triggers the verified Guardian updater immediately, with the daily updater as fallback.

Automation can detect change, apply a generic adapter, revalidate behavior, fail precisely, and install an adapter that has been published. No local tool can invent support before code exists if a future Codex release removes the current launch mechanism or introduces an unknown protocol. Guardian therefore protects the active task and reports machine-readable evidence until a verified adapter Release is available.

`GuardianState` distinguishes `Stabilizing`, `Ready`, `WaitingForProxy`, `ObservingAfterCodexUpdate`, `UpstreamSuspected`, `CodexCompatibilityReviewRequired`, `InPlaceRepairPending`, and `InPlaceRepairActive`. `Control.ps1 -Action Start` waits through the normal debounce phase and reports the resulting state.

Control the guardian itself without touching Codex or Windows networking:

```powershell
.\Control.ps1 -Action Restart
.\Control.ps1 -Action Stop
.\Control.ps1 -Action Start
.\Control.ps1 -Action SetMode -Mode Auto
.\Control.ps1 -Action CheckUpdate
```

Runtime status is in `status.json`; daily JSON Lines logs are under `logs`. Logs rotate by size, age, and count. Proxy credentials are never accepted or logged.

Guardian never restarts a running Codex process. If Codex closes unexpectedly, collect a diagnostic report and follow [Troubleshooting](TROUBLESHOOTING.en.md); the cause is outside Guardian's no-restart path.

## Uninstall

On macOS/Linux, from the extracted package:

```sh
./uninstall.sh
```

This keeps configuration and logs by default. Use `./uninstall.sh --purge` only when you deliberately want both removed.

On Windows, from the release or installation directory:

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

The release tool runs PowerShell and Go tests, creates the Windows EXE/ZIP plus four macOS/Linux archives in `artifacts`, and writes a SHA-256 for every asset. CI also tests and compiles the native guardian on Windows, macOS, and Linux. Store/MSIX and desktop integration tests still require real user sessions. See [compatibility and effectiveness testing](COMPATIBILITY-TESTING.md) for the online proof and soak-test gates.

Architecture and threat boundaries are documented in [ARCHITECTURE.md](ARCHITECTURE.md).

## License

[MIT](../LICENSE). “Codex” and “OpenAI” may be trademarks of their respective owners; see [DISCLAIMER.md](../DISCLAIMER.md).
