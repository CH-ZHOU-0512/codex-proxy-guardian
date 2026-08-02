# Changelog

All notable changes are documented here. This project follows semantic versioning after the initial alpha series.

## [0.2.0-alpha] - 2026-08-02

- Added a restart-rate circuit breaker so an unstable environment cannot keep relaunching Codex indefinitely.
- Added persisted relaunch recovery so a failed managed start is retried without creating an unlimited restart loop.
- Added deterministic candidate ordering with active-endpoint hysteresis and inherited proxy-environment discovery.
- Added multi-target OpenAI/ChatGPT HTTPS validation with configurable quorum and richer effectiveness evidence.
- Added periodic MSIX manifest re-resolution so Codex Store updates do not leave a stale executable path.
- Added recent Codex-to-proxy TCP connection evidence, lifecycle states, read-only Doctor diagnostics, and safer configuration migration.
- Broadened process and common-port discovery for current Clash/Mihomo, v2rayN/Xray, sing-box, Hiddify, Neko, and related Windows clients.

## [0.1.0-alpha] - 2026-08-02

- Initial open-source alpha.
- Added explicit/system/process-listener proxy discovery with TCP and HTTPS validation.
- Added stable-sample debounce, restart cooldown, exponential retry, rotating JSONL logs, and per-install single-instance mutex.
- Added MSIX manifest-based Codex executable discovery for x64 and ARM64.
- Added Safe default and opt-in Enforce mode.
- Added path-bound installation markers, current-user startup, silent launch, status, and guarded uninstall.
- Added static/unit tests, Windows PowerShell/PowerShell CI, release ZIP generation, checksum, documentation, and security policy.
