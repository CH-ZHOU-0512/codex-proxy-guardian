#!/bin/sh
set -eu

install_root="$HOME/.local/lib/codex-proxy-guardian"
binary="$install_root/codex-proxy-guardian"
link_root="$HOME/.local/bin"

if [ -x "$binary" ]; then
  "$binary" service uninstall || true
  "$binary" unregister-install || true
fi

for link in "$link_root/codex-proxy-guardian" "$link_root/codex-guard"; do
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$binary" ]; then
    rm -f "$link"
  fi
done

rm -f "$binary" "$binary.previous"
rmdir "$install_root" 2>/dev/null || true

if [ "${1:-}" = "--purge" ]; then
  case "$(uname -s)" in
    Darwin) rm -rf "$HOME/Library/Application Support/CodexProxyGuardian" ;;
    Linux)
      rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/codex-proxy-guardian"
      rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/codex-proxy-guardian"
      ;;
  esac
  echo "Codex Proxy Guardian and its local data were removed."
else
  echo "Codex Proxy Guardian was removed; configuration and logs were kept."
fi
