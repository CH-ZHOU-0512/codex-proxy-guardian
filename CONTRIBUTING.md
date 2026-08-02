# Contributing

Bug reports and narrowly scoped pull requests are welcome. Before submitting code:

1. Describe the Windows, Codex distribution, proxy mode, and expected behavior without including private network details.
2. Keep the no-network-mutation guarantee: do not write system proxy, WinHTTP, DNS, routes, or persistent proxy variables.
3. Preserve Safe mode as the public default.
4. Run both Windows PowerShell 5.1 and PowerShell 7 tests when available:

   ```powershell
   powershell.exe -NoProfile -File .\tests\Run-Tests.ps1
   pwsh -NoProfile -File .\tests\Run-Tests.ps1
   ```

5. Update the support matrix and changelog for user-visible behavior.

New proxy adapters must prove HTTP/HTTPS semantics, avoid credential exposure, and define deterministic precedence. Changes that can stop or restart Codex need debounce, cooldown, and a test for PID/process-handoff behavior.

By contributing, you agree that your contribution is licensed under the MIT License.
