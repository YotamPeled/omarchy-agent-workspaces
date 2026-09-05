#!/usr/bin/env bash
# Install and uninstall against a throwaway HOME, so nothing here touches your machine.
# Proves: a second install changes nothing, and uninstall gives the files back as they were.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
mkdir -p "$S/.claude" "$S/.config/omarchy" "$S/.config/hypr" "$S/.local/bin"
cat > "$S/.claude/settings.json" <<'J'
{ "model": "opus", "hooks": { "SessionStart": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "bash /somewhere/their-own.sh", "timeout": 10 } ] } ] } }
J
cat > "$S/.config/omarchy/shell.json" <<'J'
{ "version": 1, "bar": { "layout": { "left": [ {"id":"omarchy.menu"}, {"id":"omarchy.workspaces"} ] } } }
J
echo 'o.bind("SUPER + E", "Files", "nautilus")' > "$S/.config/hypr/bindings.lua"
echo 'o.launch_on_start("their-daemon")' > "$S/.config/hypr/autostart.lua"
cp -r "$S" "$S.before"; trap 'rm -rf "$S" "$S.before"' EXIT

HOME="$S" AGENT_WS_NO_RELOAD=1 "$HERE/install" >/dev/null
HOME="$S" AGENT_WS_NO_RELOAD=1 "$HERE/install" | grep -q "already there" || { echo "FAIL: second install was not a no-op"; exit 1; }
HOME="$S" AGENT_WS_NO_RELOAD=1 "$HERE/uninstall" >/dev/null

diff -r "$S.before" "$S" --exclude='*.json' >/dev/null || { echo "FAIL: files left behind"; exit 1; }
python3 - "$S" <<'P'
import json, sys
s = sys.argv[1]
for f in (".claude/settings.json", ".config/omarchy/shell.json"):
    if json.load(open(f"{s}.before/{f}")) != json.load(open(f"{s}/{f}")):
        sys.exit(f"FAIL: {f} was not restored")
P
echo "PASS: install is idempotent, uninstall restores everything"
