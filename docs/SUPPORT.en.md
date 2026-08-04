# Support matrix

## Tested design baseline

| Platform | Architectures | Codex target | System proxy source | Current-user startup |
|---|---|---|---|---|
| Windows 11 | x64, ARM64 | Store / Store-signed MSIX desktop | Internet Settings and WinHTTP PAC/WPAD resolution | Scheduled Task; HKCU Run fallback |
| macOS | Intel, Apple Silicon | ChatGPT/Codex desktop app | `scutil --proxy`, including PAC/WPAD | LaunchAgent |
| Linux | x64, ARM64 | Official Codex CLI | GNOME `gsettings`, including auto-config URLs | systemd user; XDG Autostart fallback |

All platforms accept HTTP, HTTPS, SOCKS5, and SOCKS5H endpoints with explicit ports. Sources may be explicit configuration, inherited `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`, system proxy/PAC/WPAD, or recognized loopback listeners. Unknown listeners are tested as both HTTP and SOCKS5; their protocol is never inferred from the port number alone.

PAC `FindProxyForURL` is evaluated for every configured validation target. `PROXY`, `HTTP`, `HTTPS`, `SOCKS`, `SOCKS5`, and `DIRECT` fallback entries are understood. Windows uses the current-user WinHTTP auto-proxy resolver. macOS/Linux use a JavaScript runtime bounded by document size, fetch, DNS, execution-time, and cache limits. Every resolved endpoint must still pass TCP and proxied-request quorum validation.

If a PAC returns mutually incompatible routes for the validation targets and no single endpoint reaches the configured quorum, Guardian safely declines to take over.

## Unsupported or configuration-dependent

- SOCKS4. `SOCKS4` PAC entries are ignored; expose SOCKS5, HTTP, or a mixed inbound instead.
- TUN-only modes with no system PAC/proxy endpoint and no HTTP/SOCKS5/mixed listener.
- Credential-bearing proxy URLs, to keep secrets out of process lists, command lines, and logs.
- Arbitrary non-loopback explicit/environment proxies unless `AllowNonLoopbackProxy` is enabled. System-configured remote proxies have a separate `AllowSystemNonLoopbackProxy` switch, enabled by default and available for opt-out.
- Proxy services in another user/session that cannot be attributed to the current desktop configuration.
- Group Policy requiring signed scripts or Constrained Language Mode.
- Non-MSIX or renamed third-party Windows Codex packages unless precisely configured.
- A Linux Codex desktop app. OpenAI currently ships the official CLI, which this project launches through `codex-guard`.
- Retrofitting another running terminal's environment or terminating/restarting interactive Linux Codex CLI sessions.
- macOS apps at custom paths not listed in `MacApplicationPaths`.

## Compatibility reports

Use `codex-proxy-guardian doctor` on macOS/Linux or `Doctor.ps1 -Online -Json` on Windows. Include the proxy application version and its actual mode: HTTP, mixed, pure SOCKS5, PAC/WPAD, or TUN. Remove endpoints, custom hosts, usernames, paths, IP addresses, tokens, and credentials from any raw operational data before posting it.
