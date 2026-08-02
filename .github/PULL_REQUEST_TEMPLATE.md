## Summary

Describe the user-visible behavior and compatibility target.

## Safety checklist

- [ ] Safe mode remains the default.
- [ ] No Windows/WinHTTP proxy, DNS, route, or persistent proxy environment setting is modified.
- [ ] Proxy credentials and sensitive endpoints cannot enter logs or command lines.
- [ ] Restart-related behavior includes debounce/cooldown coverage.
- [ ] Windows PowerShell 5.1 tests pass.
- [ ] Documentation and changelog are updated where needed.
