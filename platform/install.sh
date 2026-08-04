#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$script_dir/bin/codex-proxy-guardian" ]; then
  project_root="$script_dir"
else
  project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
fi
source_binary="$project_root/bin/codex-proxy-guardian"

if [ ! -f "$source_binary" ]; then
  echo "Missing release binary: $source_binary" >&2
  exit 1
fi

install_root="$HOME/.local/lib/codex-proxy-guardian"
binary="$install_root/codex-proxy-guardian"
link_root="$HOME/.local/bin"
mkdir -p "$install_root" "$link_root"

temporary="$install_root/.codex-proxy-guardian.new"
cp "$source_binary" "$temporary"
chmod 755 "$temporary"
mv -f "$temporary" "$binary"
ln -sfn "$binary" "$link_root/codex-proxy-guardian"
ln -sfn "$binary" "$link_root/codex-guard"

"$binary" register-install "$binary"
"$binary" service install

echo "Codex Proxy Guardian installed for the current user."
echo "Add $link_root to PATH if needed."
if [ "$(uname -s)" = "Linux" ]; then
  echo "Start Codex with: codex-guard"
else
  echo "Open ChatGPT/Codex normally; Guardian runs in the background."
fi
