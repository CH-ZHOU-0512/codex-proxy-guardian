# Support matrix

## Tested design baseline

| Area | Supported | Notes |
|---|---|---|
| OS | Windows 11 | Current-user interactive desktop only |
| Architecture | x64, ARM64 | Executable is resolved from the MSIX manifest |
| Codex distribution | Microsoft Store / Store-signed MSIX | Package name defaults to `OpenAI.Codex` and is configurable |
| One-click setup | Windows 11 inbox .NET Framework 4.8 | Current-user graphical setup; use the ZIP where unsigned-app policy blocks it |
| Shell | Windows PowerShell 5.1 | PowerShell 7 can run setup/tests, but the task uses inbox Windows PowerShell |
| Proxy scheme | HTTP, HTTPS | An explicit port is required |
| Windows proxy | Manual `ProxyServer` | Supports one endpoint or `http=...;https=...` forms |
| Environment proxy | `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY` | Values must describe an HTTP/HTTPS proxy and pass validation |
| Proxy process | Recognized local listener | Process patterns are configurable |
| Startup | Scheduled Task | HKCU Run is a fallback |

## Not automatically supported

- PAC files, WPAD, or automatic configuration scripts. Resolving PAC correctly requires executing policy-dependent JavaScript for each destination.
- Pure SOCKS4/SOCKS5 endpoints. This release deliberately accepts only HTTP/HTTPS proxy semantics.
- TUN-only proxy modes with no HTTP or mixed inbound listener.
- WinHTTP-only proxy settings. Codex is a desktop application; reading WinHTTP would introduce ambiguous precedence.
- Proxy services in another user/session when their listener cannot be safely attributed to the current desktop configuration.
- Proxy authentication embedded in a URL. Credentials are rejected to prevent command-line/process-list and log exposure.
- Group Policy that requires signed scripts or enforces Constrained Language Mode.
- Non-MSIX or renamed third-party Codex packages unless their package name is explicitly added and their manifest exposes a directly launchable executable.

## Compatibility reports

When opening an issue, attach the intentionally redacted report first:

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
