# macOS and Linux package

Run `./install.sh` as your normal user. Do not use `sudo`.

- macOS installs a current-user LaunchAgent and manages Codex inside the ChatGPT desktop app.
- Linux installs a systemd user service when available, otherwise an XDG autostart entry. Start Codex CLI with `codex-guard` so the validated proxy is applied to that terminal process.

Useful commands:

```sh
codex-proxy-guardian status
codex-proxy-guardian doctor
codex-proxy-guardian mode auto
codex-proxy-guardian mode strict
codex-proxy-guardian update --install
```

Run `./uninstall.sh` to remove the program while keeping configuration and logs, or `./uninstall.sh --purge` to remove both. The scripts never change system proxy, DNS, routes, firewall rules, or persistent shell environment variables.
