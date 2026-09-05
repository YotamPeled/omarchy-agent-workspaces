#!/usr/bin/env bash
# The awkward machines: no config files at all, empty ones, a bar strip that is not on the
# left, bare-string widget entries, a user hook that also calls agent-ws, damaged markers.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; ((pass++)); else echo "  FAIL $1"; echo "       want: $3"; echo "       got:  $2"; ((fail++)); fi; }
newhome() { S="$(mktemp -d)"; mkdir -p "$S/.claude" "$S/.config/omarchy" "$S/.config/hypr" "$S/.local/bin"; }
run() { HOME="$S" AGENT_WS_NO_RELOAD=1 "$HERE/$1" 2>&1; }
j() { python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))" "$1" 2>/dev/null; }

echo "a bare machine with no config files at all"
newhome; run install >/dev/null; run uninstall >/dev/null
check "leaves no shell.json behind"  "$(test -e "$S/.config/omarchy/shell.json" && echo yes || echo no)" "no"
check "leaves no settings.json behind" "$(test -e "$S/.claude/settings.json" && echo yes || echo no)" "no"
rm -rf "$S"

echo "an empty settings.json and an empty shell.json"
newhome; echo -n "" > "$S/.claude/settings.json"; echo "{}" > "$S/.config/omarchy/shell.json"
run install >/dev/null; run uninstall >/dev/null
check "shell.json ends up empty again" "$(j "$S/.config/omarchy/shell.json")" "{}"
rm -rf "$S"

echo "Omarchy's strip sitting in the centre section, not the left"
newhome
cat > "$S/.config/omarchy/shell.json" <<'J'
{"bar":{"layout":{"left":[{"id":"omarchy.menu"}],"center":[{"id":"omarchy.workspaces"},{"id":"omarchy.clock"}]}}}
J
before="$(j "$S/.config/omarchy/shell.json")"
run install >/dev/null
check "takes over the strip in place, no second one" \
  "$(python3 -c "
import json;d=json.load(open('$S/.config/omarchy/shell.json'))['bar']['layout']
print([w['id'] for w in d['center']], len(d['left']))")" \
  "['io.github.yotampeled.agent-workspaces', 'omarchy.clock'] 1"
run uninstall >/dev/null
check "puts it back exactly where it was" "$(j "$S/.config/omarchy/shell.json")" "$before"
rm -rf "$S"

echo "widget entries written as bare strings"
newhome
echo '{"bar":{"layout":{"left":["omarchy.menu","omarchy.workspaces"]}}}' > "$S/.config/omarchy/shell.json"
before="$(j "$S/.config/omarchy/shell.json")"
run install >/dev/null; run uninstall >/dev/null
check "bare strings survive the round trip" "$(j "$S/.config/omarchy/shell.json")" "$before"
rm -rf "$S"

echo "a hook of the user's own that also calls agent-ws"
newhome
cat > "$S/.claude/settings.json" <<'J'
{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"agent-ws hook pre-tool && /home/me/audit.sh","timeout":10}]}]}}
J
before="$(j "$S/.claude/settings.json")"
run install >/dev/null; run uninstall >/dev/null
check "their chained hook is still there" "$(j "$S/.claude/settings.json")" "$before"
rm -rf "$S"

echo "a bindings file whose end marker someone deleted"
newhome; run install >/dev/null
python3 - "$S" <<'P'
import sys, pathlib
p = pathlib.Path(sys.argv[1], ".config/hypr/bindings.lua")
p.write_text(p.read_text().replace("-- <<< agent-workspaces", ""))
P
out="$(run uninstall)"
check "says so instead of silently doing nothing" "$(grep -c "skipped, markers" <<<"$out")" "1"
rm -rf "$S"

echo "a shell.json with a syntax error"
newhome; run install >/dev/null
echo '{"bar": ' > "$S/.config/omarchy/shell.json"
out="$(run uninstall)"
check "still removes the hooks"       "$(grep -c 'hooks … removed 5' <<<"$out")" "1"
check "still removes the keybindings" "$(grep -c 'keybindings … removed' <<<"$out")" "1"
check "still removes agent-ws"        "$(test -e "$S/.local/bin/agent-ws" && echo yes || echo no)" "no"
rm -rf "$S"

echo "someone else's agent-ws already on the PATH"
newhome; echo "#!/bin/sh" > "$S/.local/bin/agent-ws"; chmod +x "$S/.local/bin/agent-ws"
run install >/dev/null; run uninstall >/dev/null
check "theirs is put back" "$(cat "$S/.local/bin/agent-ws")" "#!/bin/sh"
rm -rf "$S"

echo
if ((fail)); then echo "$fail failed, $pass passed"; exit 1; else echo "all $pass checks passed"; fi
