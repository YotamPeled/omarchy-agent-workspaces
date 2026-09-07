#!/usr/bin/env bash
# What happens at the moment a workspace's dot dims: the sound and the toast, and every case
# that must stay silent. Every stub records its argv one field per argument, so a check can
# tell one argument containing a space from two arguments.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; ((pass++)); else echo "  FAIL $1"; echo "       want: $3"; echo "       got:  $2"; ((fail++)); fi; }
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME
S="$(mktemp -d)"
BIN="$S/bin"; QUIET="$S/quiet"; BLIND="$S/blind"; mkdir -p "$BIN" "$QUIET" "$BLIND" "$S/.config/omarchy"

for f in omarchy-notification-send pw-play paplay canberra-gtk-play; do
  cat > "$BIN/$f" <<STUB
#!/usr/bin/env bash
{ printf '%s' "$f"; for a in "\$@"; do printf '|%s' "\$a"; done; echo; } >> "$S/fired.txt"
STUB
  chmod +x "$BIN/$f"
done
# hyprctl records its calls too, so "nothing asked Hyprland anything" is a real assertion.
cat > "$BIN/hyprctl" <<'STUB'
#!/usr/bin/env bash
echo "hyprctl|$*" >> "@LOG@"
# Assigned first: a JSON object inside ${VAR:-...} would end the expansion at its own brace.
d_mon='[{"activeWorkspace": {"id": 9}}]'
d_cli='[{"address":"0xaa","pid":1,"title":"","workspace":{"id":5}}]'
case "$*" in
  *monitors*) echo "${MONITORS:-$d_mon}" ;;
  *clients*)  echo "${CLIENTS:-$d_cli}" ;;
  *) echo "{}" ;;
esac
STUB
sed -i "s|@LOG@|$S/fired.txt|" "$BIN/hyprctl"
chmod +x "$BIN/hyprctl"
cp "$BIN/omarchy-notification-send" "$BIN/hyprctl" "$QUIET/"          # a machine with no audio player
cp "$BIN/omarchy-notification-send" "$BIN/pw-play" "$BLIND/"          # a machine with no hyprctl

seed() { mkdir -p "$S/state"; printf '%s' "$1" > "$S/state/sessions.json"; : > "$S/fired.txt"; }
fire() {  # fire <event> <agent> <payload>
  printf '%s' "$3" | PATH="${PATHDIR:-$BIN}:/usr/bin:/bin" HOME="$S" XDG_DATA_HOME="$S/share" \
    AGENT_WS_NO_AI=1 python3 "$HERE/bin/agent-ws" hook "$1" --agent "$2" --state "$S/state" \
    >"$S/err.txt" 2>&1
  rc=$?
  # The toast and the sound are spawned detached, so wait for them. A second past the point
  # where the hook itself returned is long after anything that was going to spawn has.
  for _ in $(seq 10); do grep -q "^omarchy-notification-send" "$S/fired.txt" 2>/dev/null && break; sleep 0.1; done
  sleep 0.3
}
n()     { local c; c=$(grep -c "^$1" "$S/fired.txt" 2>/dev/null); echo "${c:-0}"; }
toast() { grep "^omarchy-notification-send" "$S/fired.txt" 2>/dev/null | head -1; }
state() { python3 -c "import json;print(json.load(open('$S/state/sessions.json'))['$1']['state'])"; }
cfg()   { printf '%s' "$1" > "$S/.config/omarchy/agent-workspaces.json"; }

W='{"a":{"agent":"codex","open":true,"workspace":5,"address":"aa","state":"working","state_at":1,"about":"take a look at the boxes project"}}'
HEAD="omarchy-notification-send|--app-name|Agent Workspaces|-g|󰄬"

echo "a session that was working stops, on a workspace you are not looking at"
seed "$W"; fire Stop codex '{"session_id":"a"}'
check "says so out loud, once"  "$(n omarchy-notification-send)" "1"
check "and plays one sound"     "$(n pw-play)" "1"
check "naming the workspace and what it was doing, each as one argument" "$(toast)" \
  "$HEAD|Workspace 5 finished|take a look at the boxes project"
check "the hook itself still succeeded" "$rc" "0"

echo "the same stop arriving again on a session already idle"
: > "$S/fired.txt"; fire Stop codex '{"session_id":"a"}'
check "stays quiet: the dot dimmed once" "$(n omarchy-notification-send)" "0"

echo "a workspace you are already looking at"
seed "$W"; MONITORS='[{"activeWorkspace":{"id":5}}]' fire Stop codex '{"session_id":"a"}'
check "stays quiet: you watched it happen" "$(n omarchy-notification-send)" "0"

echo "a workspace in front of you on a second monitor"
seed "$W"; MONITORS='[{"activeWorkspace":{"id":1}},{"activeWorkspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
check "stays quiet too: it is on your screen" "$(n omarchy-notification-send)" "0"

echo "one of two recorded sessions sharing a workspace stops"
seed '{"a":{"agent":"codex","open":true,"workspace":5,"address":"aa","state":"working","state_at":1},
       "b":{"agent":"claude","open":true,"workspace":5,"address":"bb","state":"working","state_at":1}}'
fire Stop codex '{"session_id":"a"}'
check "stays quiet: the slot is still lit by the other one" "$(n omarchy-notification-send)" "0"
check "and asks Hyprland nothing, because the record already answered" "$(n hyprctl)" "0"

echo "a window with a working mark and no record, which is how the bar sees an agent already open"
seed "$W"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xcc","title":"◐ something","workspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
check "keeps the dot bright, so nothing is announced" "$(n omarchy-notification-send)" "0"

echo "an untitled window sharing the workspace"
seed "$W"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xcc","title":"","workspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
check "is not a working one" "$(n omarchy-notification-send)" "1"

echo "a window moved to another workspace since it started"
seed "$W"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":7}}]' fire Stop codex '{"session_id":"a"}'
check "is announced against the slot it is in now" "$(toast)" \
  "$HEAD|Workspace 7 finished|take a look at the boxes project"

echo "a session whose window has gone"
seed "$W"; CLIENTS='[]' fire Stop codex '{"session_id":"a"}'
check "announces nothing: the slot emptied, it did not dim" "$(n omarchy-notification-send)" "0"

echo "an agent that keeps no opening request, because the bar reads its title"
seed '{"a":{"agent":"claude","open":true,"workspace":5,"address":"aa","state":"working","state_at":1}}'
CLIENTS='[{"address":"0xaa","title":"✳ wire the odds column","workspace":{"id":5}}]' \
  fire Stop claude '{"session_id":"a"}'
check "borrows the title, without the mark it parks on" "$(toast)" \
  "$HEAD|Workspace 5 finished|wire the odds column"

echo "the mark Codex and Muse share"
seed '{"a":{"agent":"muse","open":true,"workspace":5,"address":"aa","state":"working","state_at":1}}'
CLIENTS='[{"address":"0xaa","title":"⠹ ~/projects/muse-f2","workspace":{"id":5}}]' \
  fire Stop muse '{"session_id":"a"}'
check "is stripped as well" "$(toast)" "$HEAD|Workspace 5 finished|~/projects/muse-f2"

echo "a named workspace"
echo '{"5": "rss-digest"}' > "$S/.config/omarchy/workspace-names.json"
seed "$W"; fire Stop codex '{"session_id":"a"}'
check "is announced by its name" "$(toast | cut -d'|' -f6)" "rss-digest finished"

echo "a workspace name hand-edited into the shape of an option"
echo '{"5": "--app-name=PWNED"}' > "$S/.config/omarchy/workspace-names.json"
seed "$W"; fire Stop codex '{"session_id":"a"}'
check "cannot become one" "$(toast)" "$HEAD|app-name=PWNED finished|take a look at the boxes project"
rm "$S/.config/omarchy/workspace-names.json"

echo "a NUL byte in the request a transcript gave us"
mkdir -p "$S/state"; : > "$S/fired.txt"
python3 -c "
import json
json.dump({'a': {'agent': 'codex', 'open': True, 'workspace': 5, 'address': 'aa',
                 'state': 'working', 'state_at': 1, 'about': 'fix the' + chr(0) + 'parser'}},
          open('$S/state/sessions.json', 'w'))"
fire Stop codex '{"session_id":"a"}'
check "does not take the hook down" "$rc" "0"
check "and is still announced" "$(toast)" "$HEAD|Workspace 5 finished|fix the parser"

echo "a machine with no audio player installed"
seed "$W"; PATHDIR="$QUIET" fire Stop codex '{"session_id":"a"}'
check "still gets the toast" "$(n omarchy-notification-send)" "1"

echo "a machine where Hyprland cannot be asked at all"
seed "$W"; PATHDIR="$BLIND" fire Stop codex '{"session_id":"a"}'
check "stays quiet rather than guessing" "$(n omarchy-notification-send)" "0"
check "and the hook still succeeds" "$rc" "0"
check "and the session is still recorded as idle" "$(state a)" "idle"

echo "your own sound, named in the config"
: > "$S/mine.oga"; cfg "{\"finish_sound\": \"$S/mine.oga\"}"
seed "$W"; fire Stop codex '{"session_id":"a"}'
check "is the one that plays" "$(n "pw-play|--volume|0.35|$S/mine.oga")" "1"

echo "a sound path that is not a file"
cfg '{"finish_sound": "/no/such/sound.oga"}'; seed "$W"; fire Stop codex '{"session_id":"a"}'
check "falls back to ours instead of reaching the player" \
  "$(n "pw-play|--volume|0.35|/usr/share/sounds")" "1"

echo "a sound path in the shape of an option"
cfg '{"finish_sound": "--help"}'; seed "$W"; fire Stop codex '{"session_id":"a"}'
check "never becomes one" "$(n "pw-play|--volume|0.35|--help")" "0"

echo "both switches off"
cfg '{"finish_sound": false, "finish_toast": false}'; seed "$W"; fire Stop codex '{"session_id":"a"}'
check "is silence" "$(cat "$S/fired.txt")" ""
check "with nothing asked of Hyprland either" "$(n hyprctl)" "0"
check "and the session still recorded as idle" "$(state a)" "idle"

echo "a switch written as a quoted word, the easy mistake in a JSON file"
cfg '{"finish_toast": "false", "finish_sound": "false"}'; seed "$W"; fire Stop codex '{"session_id":"a"}'
check "means off, not a truthy string" "$(cat "$S/fired.txt")" ""

echo "a config file that is not JSON"
cfg 'not json'; seed "$W"; fire Stop codex '{"session_id":"a"}'
check "falls back to the defaults" "$(n omarchy-notification-send)" "1"

echo "a config file that is JSON but not an object"
cfg '["nonsense"]'; seed "$W"
printf '{"aa": {"at": 99999999999, "sid": "a"}}' > "$S/state/needs.json"
fire Stop codex '{"session_id":"a"}'
check "does not raise out of the hook" "$rc" "0"
check "still announces on the defaults" "$(n omarchy-notification-send)" "1"
check "and the needs-you flag this session raised is still cleared" \
  "$(python3 -c "import json;print(json.load(open('$S/state/needs.json')))")" "{}"
rm -f "$S/.config/omarchy/agent-workspaces.json"

echo "a stop from a session nobody has a record of"
seed '{}'; fire Stop codex '{"session_id":"ghost"}'
check "announces nothing" "$(cat "$S/fired.txt")" ""

echo "a tool finishing mid-turn"
seed "$W"; fire PostToolUse codex '{"session_id":"a"}'
check "is not a finish" "$(n omarchy-notification-send)" "0"

echo "a subagent finishing while its parent works on"
seed "$W"; fire SubagentStop codex '{"session_id":"a"}'
check "is not a finish either" "$(n omarchy-notification-send)" "0"

echo "a session ending, which is the other way a record turns idle"
seed "$W"; fire SessionEnd codex '{"session_id":"a"}'
check "is not announced: nobody waits on a session that is gone" "$(n omarchy-notification-send)" "0"
check "and it is recorded idle all the same" "$(state a)" "idle"

rm -rf "$S"
echo; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
