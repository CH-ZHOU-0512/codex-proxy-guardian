# Compatibility and effectiveness testing

The project separates “installed successfully” from “proved effective.” A release candidate should pass all four layers below.

## Layer 1: deterministic tests

Run `tests\Run-Tests.ps1` on Windows PowerShell 5.1 and PowerShell 7. Tests cover parser behavior, credential rejection, candidate ordering, configuration migration, PID handoff, restart circuit breaking, diagnostic redaction, and the no-network-mutation contract.

## Layer 2: online proxy proof

Install with mandatory connectivity validation:

```powershell
.\Install.ps1 -RequireConnectivity
.\Doctor.ps1 -Online
```

The default test set sends unauthenticated HTTPS HEAD requests through the explicit `WebProxy` transport to three OpenAI/ChatGPT hosts and requires two successes. Expected unauthenticated responses such as HTTP `401`, `403`, and `429` count; proxy-authentication `407`, server errors, and transport failures do not.

## Layer 3: Codex process proof

After starting or using Codex, `Status.ps1` should progress from `ValidatedProxy` to `LaunchConfigured`, then ideally `TrafficObserved`. The last level requires a recently observed TCP connection from the Codex process tree to the same proxy endpoint. No packet content is captured.

## Layer 4: soak test

Run a read-only health measurement during normal work:

```powershell
.\tools\Measure-GuardianHealth.ps1 -DurationMinutes 60 -ExportPath .\soak-report.json
```

A healthy soak has no missing status, invalid proxy, or open-circuit samples and sees no more than one endpoint fingerprint when the proxy configuration was not intentionally changed. PID changes are reported separately because Codex itself can update or restart.

Maintainers should exercise at least these scenarios before promoting an alpha release:

- Store/MSIX Codex fresh install and in-place Store update;
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

## Community matrix

Compatibility is accepted only with a redacted `Doctor.ps1 -Online -Json` report and the tested proxy mode. A product name alone is insufficient because the same client can expose system proxy, mixed HTTP/SOCKS, pure SOCKS, or TUN-only behavior.

| Client family | Mode to report | Expected adapter |
|---|---|---|
| Clash Verge Rev / Mihomo Party / Clash Nyanpasu / FlClash | system proxy, mixed port, service, or TUN | manual proxy first; validated core listener fallback |
| v2rayN / Xray | system proxy, HTTP inbound, or TUN | manual proxy or validated HTTP-core listener |
| Hiddify / sing-box | system proxy, mixed/HTTP inbound, or TUN | manual proxy or validated listener |
| NekoRay / NekoBox | system proxy or HTTP inbound | manual proxy or validated listener |

TUN-only success means Windows transparently routes Codex; it does not prove this guardian supplied an explicit proxy. Reports must keep that distinction.
