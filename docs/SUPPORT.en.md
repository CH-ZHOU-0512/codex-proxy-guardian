# Support matrix

## Tested design baseline

| Platform | Architectures | Codex target | System proxy source | Current-user startup |
|---|---|---|---|---|
| Windows 11 | x64, ARM64 | Store / Store-signed MSIX desktop | Internet Settings `ProxyServer` | Scheduled Task; HKCU Run fallback |
| macOS | Intel, Apple Silicon | ChatGPT/Codex desktop app | `scutil --proxy` | LaunchAgent |
| Linux | x64, ARM64 | Official Codex CLI | GNOME `gsettings` | systemd user; XDG Autostart fallback |

Every platform requires a current-user session and an HTTP/HTTPS proxy with an explicit port. Explicit configuration, inherited `HTTPS_PROXY` / `HTTP_PROXY` / HTTP-compatible `ALL_PROXY`, and recognized loopback listeners are supported. Candidates must pass both TCP and proxied HTTP(S) quorum validation.

## Not automatically supported

- PAC files, WPAD, or automatic configuration scripts. Resolving PAC correctly requires executing policy-dependent JavaScript for each destination.
- Pure SOCKS4/SOCKS5 endpoints. This release deliberately accepts only HTTP/HTTPS proxy semantics.
- TUN-only proxy modes with no HTTP or mixed inbound listener.
- WinHTTP-only proxy settings. Codex is a desktop application; reading WinHTTP would introduce ambiguous precedence.
- Proxy services in another user/session when their listener cannot be safely attributed to the current desktop configuration.
- Proxy authentication embedded in a URL. Credentials are rejected to prevent command-line/process-list and log exposure.
- Group Policy that requires signed scripts or enforces Constrained Language Mode.
- Non-MSIX or renamed third-party Codex packages unless their package name is explicitly added and their manifest exposes a directly launchable executable.
- A Linux Codex desktop app. OpenAI does not currently ship one; the Linux edition provides `codex-guard` for the official CLI.
- Retroactively changing another Linux terminal process's environment, or automatically terminating/restarting an interactive Codex CLI session.
- A macOS desktop app installed at a custom path not listed in `MacApplicationPaths`.

## Compatibility reports

When opening an issue, attach the intentionally redacted report first:

macOS/Linux:

```sh
codex-proxy-guardian doctor
```

Windows:

```powershell
.\Doctor.ps1 -Online -Json -ExportPath .\codex-proxy-guardian-diagnostics.json
```

Also include the proxy application name/version and whether it uses system proxy, an HTTP/mixed port, or TUN mode. A product name alone is not enough to identify its routing behavior.

`Status.ps1 -Json`, `config.json`, and JSONL logs are local operational data and are **not** declared safe for public sharing. Post them only when a maintainer requests a specific field or event, and remove proxy endpoints, custom validation hosts, usernames, paths, IP addresses, tokens, and credentials first.

You may separately provide these low-risk version checks:

```powershell
Get-AppxPackage -Name OpenAI.Codex | Select-Object Name, Version, Architecture
Get-ExecutionPolicy -List
```
