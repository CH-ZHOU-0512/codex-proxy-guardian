# Architecture

## Data flow

```mermaid
flowchart LR
    A["Explicit config"] --> D["Candidate ranking"]
    B["Platform system proxy"] --> D
    C["Recognized process listeners"] --> D
    P["PAC / WPAD FindProxyForURL"] --> D
    D --> E["TCP listener check"]
    E --> F["Multi-target HTTPS-through-proxy quorum"]
    F --> G["Sampling and debounce"]
    G --> H["Active endpoint state"]
    H --> I["Platform adapter"]
    I --> J["Windows MSIX desktop"]
    I --> K["macOS desktop app"]
    I --> L["Linux codex-guard CLI"]
```

The guardian reads but never writes platform proxy configuration. Candidate priority is explicit configuration, PAC/WPAD routes, the current platform proxy, inherited proxy variables, recognized local listeners, then common loopback ports. HTTP, HTTPS, and SOCKS5 candidates become active only after TCP and explicit proxied-request validation plus debounce. Ordering is deterministic, and the current endpoint wins ties within its priority tier.

Windows delegates PAC/WPAD policy evaluation to the current-user WinHTTP auto-proxy resolver. macOS/Linux fetch and execute `FindProxyForURL` in a pure-Go JavaScript runtime bounded by source size, download time, DNS time, execution time, and cache age. PAC fallback directives are parsed in order; SOCKS4 is ignored. A resolved endpoint must still satisfy the multi-target quorum. If destination-specific PAC routes do not share a usable endpoint, the state machine remains in `WaitingForProxy` rather than flattening them into a false global route.

The Windows implementation remains PowerShell-based. macOS/Linux share a small statically linked Go core and platform adapters:

- macOS reads `scutil --proxy`, discovers listeners with `lsof`, resolves configured app bundle executables, observes an exact root process, and launches with process-scoped proxy variables plus the Chromium proxy argument.
- Linux reads GNOME `gsettings` when available and discovers listeners with `ss`. The daemon maintains validated state; `codex-guard` uses `exec` to replace itself with the official Codex CLI while preserving the TTY and arguments.
- Linux deliberately has no restart state machine for Codex itself. An interactive terminal session cannot be safely reconstructed by a background service, and OpenAI currently ships no official Linux Codex desktop app.

## Codex resolution

`Get-AppxPackage` locates a configured package name for the current user. `Get-AppxPackageManifest` supplies the application ID and relative executable. This avoids version-, username-, architecture-, and WindowsApps-path assumptions.

Root processes are matched by exact resolved executable path and absence of an Electron child-process `--type=` argument. A managed root is recognized by the normalized `--proxy-server` command-line value, which remains meaningful across launcher PID handoff.

On macOS the same exact-path/root-process rule is applied to configured ChatGPT/Codex application bundle executables; Electron child processes are excluded. A graceful AppleScript quit is attempted before a signal is sent, and the signal is allowed only for the same verified root PID. Linux never enumerates and kills Codex CLI processes.

## Restart state machine

```mermaid
stateDiagram-v2
    [*] --> Discovering
    Discovering --> Debouncing: candidate passes checks
    Debouncing --> Discovering: candidate disappears or changes
    Debouncing --> Active: stable samples and duration reached
    Active --> RestartPending: validated endpoint changes
    RestartPending --> Relaunching: cooldown and budget allow
    Relaunching --> Active: matching Codex root is confirmed
    Relaunching --> RecoveryPending: launch fails
    RecoveryPending --> Relaunching: proxy valid, retry and budget allow
    RecoveryPending --> CircuitOpen: restart limit reached
    CircuitOpen --> RecoveryPending: breaker expires
    Active --> Active: candidate unchanged
```

In Safe mode, an ordinary Codex root missing the launch argument enters an evidence grace period. If that exact process tree is observed using the validated proxy, it is left untouched; otherwise one managed repair is attempted after the grace period. In Enforce mode the missing argument is sufficient to trigger a debounced repair. Either mode can restart a running Codex instance after a validated endpoint change, and every repair uses the same cooldown, restart budget, and circuit breaker.

A recovery flag is written before the old Codex process is stopped and cleared only after a matching new root is observed. A failed launch is retried only while the proxy is still valid. A sliding restart window opens a persistent circuit breaker after the configured limit; while open, the guardian performs no further lifecycle action. This converts a bad detection or launch environment into a diagnosable degraded state instead of an endless restart loop or an unreported closed application.

## Mode and update control plane

`Settings.ps1` is a current-user WinForms front end. It delegates changes to `Control.ps1`, which maps the user-facing Automatic/Strict profiles to the internal Safe/Enforce fields, writes `config.json` atomically, and restarts only the guardian when the mode changes.

`Update.ps1` runs independently from the guardian under a daily current-user scheduled task. It selects a newer release from the fixed GitHub repository and configured channel, requires exact tag/archive/staged-version agreement, verifies the attached SHA-256, and only then invokes the staged installer. The existing installer owns migration, task repair, current-Codex adoption, and rollback-by-retention behavior; an update failure leaves the installed tree untouched until verification has completed.

The macOS/Linux daemon performs the same fixed-repository and channel selection once per day. It accepts only the current OS/architecture asset, verifies its attached SHA-256, safely extracts only regular files/directories within bounded size and count, checks the staged `VERSION`, atomically replaces the path recorded by the install marker, and executes the new binary in place. The previous binary is retained as `.previous`.

## Effectiveness evidence

1. **ValidatedProxy**: the chosen endpoint has a listener and reaches the configured HTTPS quorum through an explicit HTTP/HTTPS/SOCKS5 transport. Windows uses .NET for HTTP(S) and inbox `curl.exe` for SOCKS5; the Go core uses an explicit standard-library transport.
2. **LaunchConfigured**: a current Codex root command line contains the exact normalized `--proxy-server` token.
3. **TrafficObserved**: an established TCP connection from the Codex process tree to the chosen endpoint was observed within the configured evidence window.

Connection evidence reads only Windows TCP metadata: process ID, remote address, and remote port. It does not inspect packets, URLs, request bodies, authentication, or response content. The evidence proves local use of the endpoint, not its exit geography or policy.

The [official Codex network-isolation documentation](https://learn.chatgpt.com/docs/agent-approvals-security#network-isolation) describes upstream proxy handling for sandboxed command networking when that networking feature is enabled. Desktop control-plane connectivity and the Chromium launch flag used here remain best-effort observed compatibility behavior, so the project reports evidence rather than presenting the flag as a guaranteed Codex API.

## Persistence and isolation

- `state.json` stores the last validated endpoint and last restart time.
- Restart history, circuit-breaker expiry, pending relaunch recovery, and the last observed Codex-to-proxy connection time are persisted across guardian restarts.
- `status.json` is an atomic operational snapshot.
- JSONL logs rotate by date, size, retention, and file count.
- A mutex derived from the normalized install path gives each installation a distinct single-instance boundary.
- Proxy variables are written only to the guardian process immediately before it launches Codex. They are inherited by that process tree and never persisted to User or Machine scope.
- macOS uses a current-user LaunchAgent. Linux prefers a systemd user unit and falls back to XDG Autostart; neither requires root.
- The POSIX daemon records its PID, but Linux uninstall sends `SIGTERM` only after `/proc/<pid>/exe` resolves to the exact installed binary, preventing stale-PID termination of unrelated processes.

## Security boundaries

- URLs containing user information are rejected.
- Arbitrary explicit/environment remote proxies require opt-in. System-configured remote proxies have a separate default-on trust switch that can be disabled without breaking local proxy discovery.
- PAC source size, fetch, DNS, execution time, and cache lifetime are bounded; credential-bearing PAC and proxy URLs are rejected.
- The updater refuses a non-empty, unmarked installation directory.
- The uninstaller requires a product marker whose canonical path matches the requested root.
- Scheduled tasks, Run values, and shortcuts are removed only when they still point to that root.
- The HTTPS validation endpoint is configurable and receives only an unauthenticated HEAD request.
