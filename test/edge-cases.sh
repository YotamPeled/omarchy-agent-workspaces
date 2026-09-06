#!/usr/bin/env bash
# The awkward machines: no config files at all, empty ones, a bar strip that is not on the
# left, bare-string widget entries, a user hook that also calls agent-ws, damaged markers.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; ((pass++)); else echo "  FAIL $1"; echo "       want: $3"; echo "       got:  $2"; ((fail++)); fi; }
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME
newhome() { S="$(mktemp -d)"; mkdir -p "$S/.claude" "$S/.config/omarchy" "$S/.config/hypr" "$S/.local/bin"; }
# A machine where only some of the three agents are installed: PATH is trimmed to a stub
# directory holding just the ones named.
onlyagents() { P="$(mktemp -d)"
  for a in "$@"; do printf '#!/bin/sh\necho "$0 $*" >> "%s/calls.txt"\n' "$P" > "$P/$a"; chmod +x "$P/$a"; done; }
runwith() { HOME="$S" PATH="$P:/usr/bin:/bin" AGENT_WS_NO_RELOAD=1 "$HERE/$1" 2>&1; }
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
check "still removes the hooks"       "$(grep -c 'Claude Code hooks … removed 6' <<<"$out")" "1"
check "still removes the keybindings" "$(grep -c 'keybindings … removed' <<<"$out")" "1"
check "still removes agent-ws"        "$(test -e "$S/.local/bin/agent-ws" && echo yes || echo no)" "no"
rm -rf "$S"

echo "all three agents installed"
newhome; onlyagents claude codex muse; runwith install >/dev/null
check "writes Codex's own hook file"  "$(test -e "$S/.codex/hooks.json" && echo yes || echo no)" "yes"
check "installs Muse's plugin and approves it in one go" \
  "$(grep -cE 'plugins install .* --scope user|plugins approve agent-workspaces' "$P/calls.txt")" "2"
check "every line says which agent fired it" \
  "$(python3 -c "
import json
n=0
for f in ('$S/.claude/settings.json','$S/.codex/hooks.json'):
    for ev in json.load(open(f))['hooks'].values():
        for g in ev:
            for h in g['hooks']:
                if h['command'].startswith('agent-ws hook') and '--agent ' in h['command']: n+=1
print(n)")" "12"
check "Codex is asked for the user by permission request, not notification" \
  "$(python3 -c "
import json
ks=set(json.load(open('$S/.codex/hooks.json'))['hooks'])
print('PermissionRequest' in ks, 'Notification' in ks)")" "True False"
check "the Muse plugin names the agent in every line too" \
  "$(python3 -c "
import json
hs=json.load(open('$HERE/muse-plugin/.muse-plugin/plugin.json'))['capabilities']['hooks']
print(len(hs), all(h['command'][:2]==['agent-ws','hook'] and h['command'][-2:]==['--agent','muse'] for h in hs))")" "6 True"
check "a second install changes nothing" "$(grep -c 'hooks … already there' <<<"$(runwith install)")" "2"
runwith uninstall >/dev/null
check "takes back the files and the folders it made" \
  "$(test -e "$S/.codex/hooks.json" -o -d "$S/.codex" && echo left || echo clean)" "clean"
check "and takes the Muse plugin back out" "$(grep -c 'plugins remove agent-workspaces' "$P/calls.txt")" "1"
rm -rf "$S" "$P"

echo "a machine with Claude only"
newhome; onlyagents claude; runwith install > "$S/out.txt" 2>&1
check "says the other two are skipped" "$(grep -c 'not installed, skipped' "$S/out.txt")" "2"
check "writes nothing into their config" \
  "$(test -e "$S/.codex/hooks.json" && echo wrote || echo none)" "none"
check "and asks Muse for nothing" "$(test -e "$P/calls.txt" && grep -c plugins "$P/calls.txt" || echo 0)" "0"
check "still wires Claude" "$(grep -c 'Claude Code hooks … added 6' "$S/out.txt")" "1"
rm -rf "$S" "$P"

echo "an agent config of the user's own, with their hooks already in it"
newhome; onlyagents claude codex muse
mkdir -p "$S/.codex"
cat > "$S/.codex/hooks.json" <<'J'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash /theirs.sh","timeout":10}]}]}}
J
theirs="$(j "$S/.codex/hooks.json")"
runwith install >/dev/null; runwith uninstall >/dev/null
check "their file comes back exactly as it was" "$(j "$S/.codex/hooks.json")" "$theirs"
check "and it is not deleted from under them" "$(test -e "$S/.codex/hooks.json" && echo yes || echo no)" "yes"
rm -rf "$S" "$P"

echo "upgrading from the previous release"
newhome; onlyagents claude
python3 - "$S" <<'P'
import json, sys
s = sys.argv[1]
old = lambda sub: {"matcher": "*", "hooks": [{"type": "command",
                   "command": f"agent-ws hook {sub}", "timeout": 10}]}
json.dump({"model": "opus", "hooks": {e: [old(sub)] for e, sub in (
    ("SessionStart", "session-start"), ("SessionEnd", "session-end"),
    ("Notification", "notification"), ("UserPromptSubmit", "prompt-submit"),
    ("PreToolUse", "pre-tool"))}}, open(f"{s}/.claude/settings.json", "w"), indent=2)
P
runwith install >/dev/null
check "every line ends up naming its own agent, not just the new one" \
  "$(python3 -c "
import json
h = json.load(open('$S/.claude/settings.json'))['hooks']
lines = [x['command'] for ev in h.values() for g in ev for x in g['hooks']]
print(len(lines), sum('--agent claude' in c for c in lines))")" "6 6"
runwith uninstall >/dev/null
check "and uninstall still takes every one of them back" \
  "$(python3 -c "
import json
d = json.load(open('$S/.claude/settings.json'))
lines = [x['command'] for ev in d.get('hooks', {}).values() for g in ev for x in g['hooks']]
print(len(lines), d.get('model'))")" "0 opus"
rm -rf "$S" "$P"

echo "a hook of the user's own, written exactly the way we would write it"
newhome; onlyagents claude
python3 - "$S" <<'P'
import json, sys
s = sys.argv[1]
theirs = {"matcher": "*", "hooks": [{"type": "command",
          "command": "agent-ws hook session-start --agent claude", "timeout": 10}]}
json.dump({"model": "opus", "hooks": {"SessionStart": [theirs]}},
          open(f"{s}/.claude/settings.json", "w"), indent=2)
P
before="$(j "$S/.claude/settings.json")"
out="$(runwith install)"
check "install adds five, not six, because theirs already covers one" \
  "$(grep -c 'Claude Code hooks … added 5' <<<"$out")" "1"
runwith uninstall >/dev/null
check "their line survives uninstall" "$(j "$S/.claude/settings.json")" "$before"
rm -rf "$S" "$P"

echo "a hook of the user's own that calls agent-ws with their own arguments"
newhome; onlyagents claude
python3 - "$S" <<'P'
import json, sys
theirs = {"matcher": "*", "hooks": [{"type": "command",
          "command": "bash ~/mine.sh && agent-ws hook pre-tool", "timeout": 30}]}
json.dump({"model": "opus", "hooks": {"PreToolUse": [theirs]}},
          open(f"{sys.argv[1]}/.claude/settings.json", "w"), indent=2)
P
before="$(j "$S/.claude/settings.json")"
runwith install >/dev/null
check "we leave it alone and add ours beside it" \
  "$(python3 -c "
import json
h = json.load(open('$S/.claude/settings.json'))['hooks']['PreToolUse']
c = [x['command'] for g in h for x in g['hooks']]
print(len(c), any(x.startswith('bash ~/mine.sh') for x in c))")" "2 True"
runwith uninstall >/dev/null
check "and it is exactly as they left it" "$(j "$S/.claude/settings.json")" "$before"
rm -rf "$S" "$P"

echo "a machine whose state folder is not the usual one"
newhome; onlyagents claude codex muse
mkdir -p "$S/.state"
HOME="$S" XDG_STATE_HOME="$S/.state" PATH="$P:/usr/bin:/bin" AGENT_WS_NO_RELOAD=1 "$HERE/install" >/dev/null 2>&1
check "every hook line carries the folder, so a hook stripped of its environment still finds it" \
  "$(python3 -c "
import json
n = 0
for f in ('$S/.claude/settings.json', '$S/.codex/hooks.json'):
    for ev in json.load(open(f))['hooks'].values():
        for g in ev:
            for h in g['hooks']:
                if '--state $S/.state/omarchy/agent-workspaces' in h['command']: n += 1
print(n)")" "12"
check "and so does the copy of the plugin it installs" \
  "$(python3 -c "
import json
hs = json.load(open('$S/.state/omarchy/agent-workspaces/muse-plugin/.muse-plugin/plugin.json'))['capabilities']['hooks']
print(len(hs), all(h['command'][-2:] == ['--state', '$S/.state/omarchy/agent-workspaces'] for h in hs))")" "6 True"
check "the download itself is left alone" \
  "$(python3 -c "
import json
hs = json.load(open('$HERE/muse-plugin/.muse-plugin/plugin.json'))['capabilities']['hooks']
print(any('--state' in h['command'] for h in hs))")" "False"
rm -rf "$S" "$P"

echo "someone else's agent-ws already on the PATH"
newhome; echo "#!/bin/sh" > "$S/.local/bin/agent-ws"; chmod +x "$S/.local/bin/agent-ws"
run install >/dev/null; run uninstall >/dev/null
check "theirs is put back" "$(cat "$S/.local/bin/agent-ws")" "#!/bin/sh"
rm -rf "$S"

echo "it binds only its own keys and never rebinds one of Omarchy's"
newhome; run install >/dev/null
check "adds no binding for Super+Shift+A" \
  "$(grep -c 'SHIFT + A"' "$S/.config/hypr/bindings.lua")" "0"
check "unbinds nothing at all" \
  "$(grep -c 'hl.unbind' "$S/.config/hypr/bindings.lua")" "0"
check "binds exactly its own three keys" \
  "$(grep -c '^o.bind(' "$S/.config/hypr/bindings.lua")" "3"
rm -rf "$S"

echo
if ((fail)); then echo "$fail failed, $pass passed"; exit 1; else echo "all $pass checks passed"; fi
