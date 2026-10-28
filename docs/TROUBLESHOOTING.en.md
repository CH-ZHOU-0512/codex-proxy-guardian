# Troubleshooting

## macOS/Linux first checks

```sh
codex-proxy-guardian version
codex-proxy-guardian status
codex-proxy-guardian doctor
```

If the command is missing, add `~/.local/bin` to `PATH` or invoke `~/.local/lib/codex-proxy-guardian/codex-proxy-guardian` directly. Logs are under `~/Library/Application Support/CodexProxyGuardian/logs` on macOS or `${XDG_STATE_HOME:-~/.local/state}/codex-proxy-guardian/logs` on Linux.

### Plain `codex` on Linux does not use Guardian

This is an intentional platform boundary: a background process cannot safely rewrite an already-started terminal's environment. Start with `codex-guard`, which injects the currently validated endpoint and passes all arguments through. Guardian never terminates or restarts interactive CLI sessions.

### Linux remains at `WaitingForProxy`

Make sure the proxy application exposes HTTP, SOCKS5, or a mixed listener. TUN-only routing with no system PAC/proxy endpoint still cannot be explicitly validated. On non-GNOME desktops, set `ExplicitProxy` in `${XDG_CONFIG_HOME:-~/.config}/codex-proxy-guardian/config.json`.

### macOS cannot find the desktop app

If status shows `CodexApplicationUnavailable`, make sure ChatGPT/Codex is under `/Applications` or `~/Applications`. Add custom locations to `MacApplicationPaths`. Guardian will not use a fuzzy process-name match to terminate an unknown application.

### macOS/Linux startup is missing

- macOS: run `launchctl print gui/$(id -u)/io.github.ch-zhou-0512.codex-proxy-guardian`; rerun `./install.sh` to repair the user LaunchAgent.
- Linux: run `systemctl --user status codex-proxy-guardian.service`; without user systemd, inspect `~/.config/autostart/codex-proxy-guardian.desktop`.

Do not use `sudo` for install, repair, or uninstall.

## Codex was closed unexpectedly

Starting with v1.8.0, Guardian publishes `CodexRestartPolicy=Never` and has no Codex shutdown call path. If Codex still exits, capture the timestamp and inspect Codex, Windows, and proxy-leader logs. Reinstalling v1.8.0 or newer in place removes legacy lifecycle behavior while preserving proxy configuration.

## In-place repair after a Windows proxy-port change

Guardian can bind a released old loopback port and forward it to a newly validated endpoint when both endpoints use the same HTTP-family or SOCKS5-family protocol. `InPlaceProxyRelayActive=true` confirms the relay is active.

`InPlaceRepairPending` means that the old port is still occupied, no compatible source endpoint is known, or the protocols differ. Guardian leaves Codex open and does not seize the port or modify Windows networking. Setting `ExplicitProxy` to a stable HTTP or mixed inbound can reduce endpoint churn.

## Automatic update failed

Run `Control.ps1 -Action CheckUpdate` to inspect the configured channel. Update logs are under `logs\update-*.jsonl`. GitHub reachability, incomplete Release assets, a SHA-256 mismatch, or a missing task can block an update; each failure retains the current version rather than partially overwriting it. Re-run the newest `Install.ps1` to restore a missing `Codex Proxy Guardian Update` task.

Starting with v1.4.4, Settings distinguishes “another updater is running; this check was skipped” from a completed “no higher version” result. It displays the installed version, remote version, selected channel, and check time. A skipped check is never labeled current.

Starting with v1.5.2, the Windows updater prefers Guardian's validated route: PowerShell handles HTTP/HTTPS and Windows 11 `curl.exe` handles SOCKS5/SOCKS5H. `CompatibilityUpdateCheckState=FailedRetryScheduled` means the request actually failed and a retry is scheduled; `CompatibilityUpdateRetryAfterUtc` gives the next time. `Current` is emitted only after GitHub was reached successfully. If a v1.5.1 installation repeatedly logs network failures, install the latest stable version in place once—the defect being repaired is inside that old updater.

Starting with v1.5.4, a successful background update sends one desktop notification with the previous and installed versions and explicitly says that Codex does not need to restart. Delivery is logged as `automatic_update_notification_shown` or `automatic_update_notification_failed`, and the same version is not announced again at each login. Set `NotifyAfterAutomaticUpdate` to `false` in `config.json` to disable it.

## Codex was not restarted but still shows Reconnecting

Check `InPlaceProxyRelayActive`. If it is true while Codex records TLS EOF, WebSocket reset, Windows `10054`, or a request timeout, the streaming connection was normally interrupted upstream of Guardian.

Starting with v1.5.1, check `StreamingProxyGuaranteed` first:

- `false`, or `EffectivenessEvidence=SystemProxyHttpTrafficOnly`: the ordinary launch proved only that HTTP used the Windows system proxy. Guardian keeps Codex open and attempts a compatible in-place relay when the old endpoint is known.
- `true` with `EffectivenessEvidence=ManagedTrafficObserved`: managed launch configuration and endpoint traffic were both observed. If reconnects remain and no Guardian lifecycle event exists, inspect the upstream provider node.

Version 1.4.4 requires the critical `chatgpt.com` probe to pass and exposes `ProxyCriticalTargetsPassed` and `ProxyCriticalFailures` in status and Doctor output. If the proxy application's own log reports upstream `i/o timeout`, select a healthier node there.

Starting with v1.5.0, a newly started Store/MSIX Codex package enters `ObservingAfterCodexUpdate`: by default it must accumulate three fresh critical-target validations over at least 60 seconds. Guardian also starts its owned verified update task immediately. Cached results do not count, and one local proxy connection is not accepted prematurely as a stable Safe-mode conclusion.

`GuardianState=UpstreamSuspected` means the local proxy listener remains reachable while a critical external validation failed. Guardian keeps Codex open and does not restart it, change subscription nodes inside the proxy application, or modify the system proxy for this condition. If reconnects continue, select a healthier node in Clash/Mihomo/v2rayN. A later fresh critical-target success clears the state automatically.

`StreamStability=IndirectEvidenceOnly` is not an error. It states that short HTTPS probes and local TCP metadata cannot externally prove the stability of an authenticated long-lived SSE/HTTP stream.

`CodexCompatibilityReviewRequired` means one user-approved Managed launch was still not confirmed by launch-argument or traffic evidence after the timeout. Guardian keeps the current Codex open and disables further automatic lifecycle actions for that Codex/Guardian combination. Immediate and daily verified update checks continue; installation of a newer Guardian clears the old hold and reruns the audit.

## No proxy is selected

- Confirm the endpoint is HTTP, HTTPS, SOCKS5, or SOCKS5H. SOCKS4 is not supported.
- Confirm the local proxy application exposes an HTTP, SOCKS5, or mixed inbound listener.
- Check that Windows manual proxy is enabled, or set `ExplicitProxy`.
- Run the self-test from the installed directory:

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Watch-CodexProxy.ps1 -SelfTest
  ```

Exit code `2` means no candidate passed both TCP and HTTPS validation. A proxy may be listening but unable to reach the configured `ProxyTestUrls`.

For a fuller, redacted diagnosis:

```powershell
.\Doctor.ps1 -Online
```

The default requires at least two successful HTTPS targets. This makes a listener-only false positive much less likely.

## PAC/WPAD is enabled but no candidate is selected

- Windows uses the current-user WinHTTP auto-proxy resolver. Confirm the setup script or automatic-detection option is enabled for that user.
- On macOS inspect `ProxyAutoConfigURLString` / `ProxyAutoDiscoveryEnable` in `scutil --proxy`; on GNOME inspect proxy `mode` and `autoconfig-url` with `gsettings`.
- A PAC that returns SOCKS4, only DIRECT, or mutually incompatible endpoints for the OpenAI validation targets safely produces no selected proxy.
- System PAC results may use remote proxies while `AllowSystemNonLoopbackProxy` is enabled. A manually supplied `ExplicitPAC` still requires `AllowNonLoopbackProxy: true` for remote results.
- Fetch, DNS, and JavaScript execution limits reject a stalled or hostile PAC. Do not raise them without first inspecting the script.

## Status says ValidatedProxy but not ManagedTrafficObserved

`ValidatedProxy` proves the endpoint can carry the configured HTTPS checks. `LaunchConfigured` adds proof that the current Codex root carries the matching proxy argument. `ManagedTrafficObserved` appears only after a managed launch and a live Codex process-tree TCP connection to that endpoint are both observed. `SystemProxyHttpTrafficOnly` proves useful ordinary-launch HTTP traffic but is deliberately not treated as full streaming proxy inheritance. Open or continue a Codex task, then check status again. Short-lived connections can be missed; absence of traffic evidence is not by itself proof of failure.

## Codex is not found

This release supports the current user's Store/MSIX package. Verify:

```powershell
Get-AppxPackage -Name OpenAI.Codex | Select-Object Name, Version, InstallLocation
```

For a compatible renamed package, add its exact package name to `CodexPackageNames`. Do not add a generic package merely because its executable happens to have a similar name.

## Installation is blocked by execution policy

`-ExecutionPolicy Bypass` affects process policy but does not override `MachinePolicy` or `UserPolicy`. If the installer reports a Group Policy restriction or Constrained Language Mode, ask the administrator to review and sign/allow the scripts. The project should not weaken enterprise policy.

## Task Scheduler registration fails

Setup attempts a current-user interactive scheduled task, then records an HKCU Run fallback. Run `Status.ps1` and inspect `startupMode`/`startupError` in `.cpg-install.json`. A task-name or Run-value collision is treated as an error instead of overwriting another program.

## Roll back completely

```powershell
.\Uninstall.ps1 -KeepLogs -Confirm:$false
```

The uninstaller removes only a matching marked installation. Windows proxy, WinHTTP, routes, DNS, and persistent environment variables are untouched.
