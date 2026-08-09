# Compatibility and effectiveness testing

The project separates “installed successfully” from “proved effective.” A release candidate should pass all four layers below.

## Layer 1: deterministic tests

Run `tests\Run-Tests.ps1` on Windows PowerShell 5.1 and PowerShell 7, plus `go test ./...` on Windows, macOS, and Linux. Tests cover parser behavior, credential rejection, candidate ordering, configuration migration, PID handoff, restart circuit breaking, diagnostic redaction, semantic release selection, safe archive extraction, and the no-network-mutation contract.

## Layer 2: online proxy proof

Install with mandatory connectivity validation:

```powershell
.\Install.ps1 -RequireConnectivity
.\Doctor.ps1 -Online
```

The default test set sends unauthenticated HTTPS HEAD requests through the explicit `WebProxy` transport to three OpenAI/ChatGPT hosts and requires two successes. Expected unauthenticated responses such as HTTP `401`, `403`, and `429` count; proxy-authentication `407`, server errors, and transport failures do not.

On macOS/Linux use `codex-proxy-guardian doctor` and `status --json`. The Go core uses an explicit `http.Transport` proxy, not ambient routing, and applies the same success quorum.

## Layer 3: Codex process proof

After a managed Windows launch, `Status.ps1` should progress from `ValidatedProxy` to `LaunchConfigured`, then ideally `ManagedTrafficObserved`. An ordinary Explorer/Start-menu launch that only produces system-proxy HTTP traffic must report `SystemProxyHttpTrafficOnly`, `StreamingProxyGuaranteed=false`, and request a guarded managed repair after the Safe grace period. Declining or timing out the prompt must leave the current PID unchanged. Approving it must relaunch with matching Chromium proxy arguments and process-scoped HTTP/HTTPS/ALL/WS/WSS variables. No packet content is captured.

After a Store/MSIX Codex version change, the new root should first report `ObservingAfterCodexUpdate` and accumulate only fresh validations. The default acceptance point is three successful critical-target samples over at least 60 seconds. Force one critical-target failure while leaving the local listener open and verify that status becomes `UpstreamSuspected`, the current Codex PID remains unchanged, no `codex_restart` event is written, and the Windows system proxy remains unchanged. A later fresh success should clear the suspected state.

Verify that the version transition starts only the update task owned by the canonical install marker and exact installed `Update.ps1` action. Simulate an unconfirmed managed launch past `CodexCompatibilityConfirmationSeconds`; status must become `CodexCompatibilityReviewRequired`, recovery intent must be cleared, and subsequent automatic lifecycle decisions must remain held. Changing either the Codex version or Guardian version must clear that pair-specific hold and restart the audit.

`StreamStability=IndirectEvidenceOnly` is the expected steady-state limitation. The test suite must not reinterpret a short unauthenticated HTTPS probe or local TCP metadata as proof of an authenticated long-lived SSE/HTTP stream.

On macOS, `status` exposes the corresponding `activeProxyValid`, `launchConfigured`, and `trafficObserved` fields. On Linux, effectiveness is split intentionally: the daemon proves the endpoint, while starting through `codex-guard` proves deterministic process-scoped injection. The guardian never restarts an interactive CLI session.

## Layer 4: soak test

Run a read-only health measurement during normal work:

```powershell
.\tools\Measure-GuardianHealth.ps1 -DurationMinutes 60 -ExportPath .\soak-report.json
```

A healthy soak has no missing status, invalid proxy, or open-circuit samples and sees no more than one endpoint fingerprint when the proxy configuration was not intentionally changed. PID changes are reported separately because Codex itself can update or restart.

Maintainers should exercise at least these scenarios before promoting any release, especially when moving from prerelease to stable:

- Store/MSIX Codex fresh install and in-place Store update;
- post-update observation with cached-result rejection, critical-target failure, recovery, and unchanged Codex PID;
- x64 plus ARM64 community confirmation;
- manual system proxy, explicit proxy, inherited environment proxy, and recognized-process listener;
- proxy application absent at login then started later;
- endpoint port switch, short listener flap, invalid HTTP listener, and proxy-authentication response;
- Codex already running during guardian install;
- Safe and Enforce modes;
- scheduled-task registration and HKCU Run fallback;
- update preserving custom configuration;
- uninstall from a custom path with no Windows proxy change;
- forced repeated change simulation proving that the circuit breaker opens.
- macOS LaunchAgent install/upgrade/uninstall on Intel and Apple Silicon, including an app opened outside Guardian;
- Linux systemd user and XDG fallback, `codex-guard` argument/TTY preservation, exact-PID uninstall safety, and x64/ARM64 package execution;
- automatic update selecting only the exact OS/architecture archive and rejecting a path-traversal archive.

## Community matrix

Compatibility is accepted only with a redacted `Doctor.ps1 -Online -Json` report and the tested proxy mode. A product name alone is insufficient because the same client can expose system proxy, mixed HTTP/SOCKS, pure SOCKS5, PAC/WPAD, or TUN-only behavior. SOCKS5 acceptance requires a real proxied request, not just a listening port; PAC acceptance records the effective endpoint selected for the configured OpenAI target set.

| Client family | Mode to report | Expected adapter |
|---|---|---|
| Clash Verge Rev / Mihomo Party / Clash Nyanpasu / FlClash | system proxy, mixed port, service, or TUN | manual proxy first; validated core listener fallback |
| v2rayN / Xray | system proxy, HTTP inbound, or TUN | manual proxy or validated HTTP-core listener |
| Hiddify / sing-box | system proxy, mixed/HTTP inbound, or TUN | manual proxy or validated listener |
| NekoRay / NekoBox | system proxy or HTTP inbound | manual proxy or validated listener |

TUN-only success means Windows transparently routes Codex; it does not prove this guardian supplied an explicit proxy. Reports must keep that distinction.
