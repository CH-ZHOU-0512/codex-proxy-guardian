# Troubleshooting

## Codex repeatedly restarts

1. Stop the task immediately without changing network settings:

   ```powershell
   Stop-ScheduledTask -TaskName 'Codex Proxy Guardian'
   ```

2. Set `Mode` to `Safe` and `ManageExternalCodexLaunches` to `false` in the installed `config.json`.
3. Inspect `status.json` and the newest `logs\guardian-*.jsonl` file. Repeated `proxy_changed` events indicate an unstable candidate selection; repeated `unmanaged_codex` events indicate Enforce mode is not observing the expected launch argument.
4. Set `ExplicitProxy` to the stable HTTP/mixed inbound endpoint if automatic discovery sees multiple listeners.
5. Increase `DebounceSeconds`, `StableSamples`, or `RestartCooldownSeconds` for a proxy application that recreates listeners during profile switches.

The watchdog intentionally matches `--proxy-server=<validated URI>` on the current root process. It does not use launcher PID ownership, which is unreliable during MSIX/Electron process handoff.

## No proxy is selected

- Confirm the endpoint is HTTP or HTTPS, not SOCKS-only.
- Confirm the local proxy application exposes an HTTP or mixed inbound listener.
- Check that Windows manual proxy is enabled, or set `ExplicitProxy`.
- Run the self-test from the installed directory:

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Watch-CodexProxy.ps1 -SelfTest
  ```

Exit code `2` means no candidate passed both TCP and HTTPS validation. A proxy may be listening but unable to reach the configured `ProxyTestUrls`.

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
