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
[ -n "${WEDGE:-}" ] && sleep "$WEDGE"
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
cp "$BIN/omarchy-notification-send" "$BIN/hyprctl" "$QUIET/"
for f in pw-play paplay canberra-gtk-play; do : > "$QUIET/$f"; chmod 000 "$QUIET/$f"; done  # unrunnable
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
# Silence is both halves: a check that counts only toasts lets a sound through.
quiet() { local c; c=$(grep -ac -E "^(omarchy-notification-send|pw-play|paplay|canberra-gtk-play)" "$S/fired.txt" 2>/dev/null); echo "${c:-0}"; }
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
check "stays quiet: the dot dimmed once" "$(quiet)" "0"

echo "a workspace you are already looking at"
seed "$W"; MONITORS='[{"activeWorkspace":{"id":5}}]' fire Stop codex '{"session_id":"a"}'
check "stays quiet: you watched it happen" "$(quiet)" "0"

echo "a workspace in front of you on a second monitor"
seed "$W"; MONITORS='[{"activeWorkspace":{"id":1}},{"activeWorkspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
check "stays quiet too: it is on your screen" "$(quiet)" "0"

TWO='{"a":{"agent":"codex","open":true,"workspace":5,"address":"aa","state":"working","state_at":1,"about":"boxes"},
       "b":{"agent":"claude","open":true,"workspace":5,"address":"bb","state":"working","state_at":1}}'

echo "one of two sessions sharing a workspace stops while the other is still spinning"
seed "$TWO"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xbb","title":"⠙ still going","workspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
check "stays quiet: the slot is still lit by the other one" "$(quiet)" "0"

echo "the same pair, where the other one's title says it has parked"
seed "$TWO"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xbb","title":"✳ parked","workspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
check "announces: the idle mark is not a working one, whatever the record says" \
  "$(n omarchy-notification-send)" "1"

echo "a co-tenant on record whose window has since moved elsewhere"
seed "$TWO"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xbb","title":"⠙ elsewhere","workspace":{"id":3}}]' \
  fire Stop codex '{"session_id":"a"}'
check "no longer votes in the workspace it left" "$(n omarchy-notification-send)" "1"

echo "both of them stopping in the same breath"
seed "$TWO"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xbb","title":"","workspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xbb","title":"","workspace":{"id":5}}]' \
  fire Stop claude '{"session_id":"b"}'
check "dims one dot and is said once" "$(n omarchy-notification-send)" "1"

echo "a window with a working mark and no record, which is how the bar sees an agent already open"
seed "$W"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xcc","title":"◐ something","workspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
check "keeps the dot bright, so nothing is announced" "$(quiet)" "0"

echo "the mark Codex and Muse share, on a window with no record either"
seed "$W"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xcc","title":"⠹ something","workspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
check "keeps the dot bright just the same" "$(quiet)" "0"

echo "an untitled window sharing the workspace"
seed "$W"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xcc","title":"","workspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
check "is not a working one" "$(n omarchy-notification-send)" "1"

echo "a spinning window in a different workspace"
seed "$W"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xcc","title":"◐ elsewhere","workspace":{"id":3}}]' \
  fire Stop codex '{"session_id":"a"}'
check "has no bearing on this slot" "$(n omarchy-notification-send)" "1"

echo "a session in a workspace the strip draws no slot for"
seed "$W"; CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":-98}}]' fire Stop codex '{"session_id":"a"}'
check "a scratchpad dims nothing and is in front of you besides" "$(quiet)" "0"
seed "$W"; CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":12}}]' fire Stop codex '{"session_id":"a"}'
check "and neither does anything past the tenth" "$(quiet)" "0"

echo "a record holding the address in the other spelling Hyprland uses"
seed '{"a":{"agent":"codex","open":true,"workspace":5,"address":"0xaa","state":"working","state_at":1,"about":"boxes"}}'
fire Stop codex '{"session_id":"a"}'
check "still finds its own window" "$(n omarchy-notification-send)" "1"

echo "a monitor record with a null workspace"
seed "$W"; MONITORS='[{"activeWorkspace":null}]' fire Stop codex '{"session_id":"a"}'
check "does not take the hook down" "$rc" "0"
check "and is announced, because no monitor is showing it" "$(n omarchy-notification-send)" "1"

echo "a monitors answer that is not a list at all"
seed "$W"; MONITORS='{"broken": true}' fire Stop codex '{"session_id":"a"}'
check "stays quiet: we could not find out where you are" "$(quiet)" "0"

echo "a compositor that has stopped answering"
seed "$W"; WEDGE=4 fire Stop codex '{"session_id":"a"}'
check "gives the turn back rather than hanging in it" "$rc" "0"
check "and says nothing" "$(quiet)" "0"
check "with the session still recorded as idle" "$(state a)" "idle"

echo "only the toast switched off"
cfg '{"finish_toast": false}'; seed "$W"; fire Stop codex '{"session_id":"a"}'
check "still plays the sound" "$(n pw-play)" "1"
check "and shows nothing" "$(n omarchy-notification-send)" "0"

echo "only the sound switched off"
cfg '{"finish_sound": false}'; seed "$W"; fire Stop codex '{"session_id":"a"}'
check "still shows the toast" "$(n omarchy-notification-send)" "1"
check "and plays nothing" "$(n pw-play)" "0"
rm -f "$S/.config/omarchy/agent-workspaces.json"

echo "a window moved to another workspace since it started"
seed "$W"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":7}}]' fire Stop codex '{"session_id":"a"}'
check "is announced against the slot it is in now" "$(toast)" \
  "$HEAD|Workspace 7 finished|take a look at the boxes project"

echo "a session whose window has gone"
seed "$W"; CLIENTS='[]' fire Stop codex '{"session_id":"a"}'
check "announces nothing: the slot emptied, it did not dim" "$(quiet)" "0"

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

echo "a machine where no audio player can be run"
seed "$W"; PATHDIR="$QUIET" fire Stop codex '{"session_id":"a"}'
check "still gets the toast" "$(n omarchy-notification-send)" "1"
check "and the hook still succeeds" "$rc" "0"

echo "a machine where Hyprland cannot be asked at all"
seed "$W"; PATHDIR="$BLIND" fire Stop codex '{"session_id":"a"}'
check "stays quiet rather than guessing" "$(quiet)" "0"
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

echo "a window whose address Hyprland has since handed to something else"
seed '{"a":{"agent":"codex","open":true,"workspace":5,"address":"aa","pid":1,"state":"working","state_at":1,"about":"boxes"}}'
CLIENTS='[{"address":"0xaa","pid":2,"title":"","workspace":{"id":5}}]' fire Stop codex '{"session_id":"a"}'
check "is not this session's window, so nothing is announced" "$(quiet)" "0"

echo "a co-tenant with no mark in its title, given something to do while we asked Hyprland"
seed "$TWO"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xbb","title":"","workspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
check "is still believed, because no title outranks it" "$(quiet)" "0"

echo "a record with a null in it, which is not a session at all"
seed '{"a":{"agent":"codex","open":true,"workspace":5,"address":"aa","state":"working","state_at":1,"about":"boxes"},
       "b":null}'
fire Stop codex '{"session_id":"a"}'
check "does not take the state write down with it" "$(state a)" "idle"
check "and the hook still succeeds" "$rc" "0"

echo "a name carrying a dash further along, after a dash that gets stripped"
echo '{"5": "- --app-name=X"}' > "$S/.config/omarchy/workspace-names.json"
seed "$W"; fire Stop codex '{"session_id":"a"}'
check "is stripped to something that cannot be an option" "$(toast | cut -d'|' -f6)" "app-name=X finished"
rm "$S/.config/omarchy/workspace-names.json"

echo "a named session whose window has moved into another named workspace"
echo '{"5": "origin", "7": "destination"}' > "$S/.config/omarchy/workspace-names.json"
seed '{"a":{"agent":"codex","open":true,"workspace":5,"address":"aa","name":"origin","state":"working","state_at":1,"about":"boxes"}}'
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":7}}]' fire Stop codex '{"session_id":"a"}'
check "is announced by the name of the slot it is in now" "$(toast | cut -d'|' -f6)" "destination finished"
rm "$S/.config/omarchy/workspace-names.json"

echo "a preferences file that is not text at all"
printf '\xff\xfe not utf-8' > "$S/.config/omarchy/agent-workspaces.json"
seed "$W"; fire Stop codex '{"session_id":"a"}'
check "does not take the hook down" "$rc" "0"
check "and falls back to the defaults" "$(n omarchy-notification-send)" "1"
rm -f "$S/.config/omarchy/agent-workspaces.json"

echo "a sound named like an option that really is a file, in whatever directory we were run from"
: > "$S/--help"    # a real file, named like an option, in the directory we will run from
cfg '{"finish_sound": "--help"}'; seed "$W"; ( cd "$S" && fire Stop codex '{"session_id":"a"}' )
check "is refused for not saying where it is" "$(n "pw-play|--volume|0.35|--help")" "0"
rm -f "$S/.config/omarchy/agent-workspaces.json"

echo "a session finishing a moment after one beside it already spoke"
mkdir -p "$S/state"; : > "$S/fired.txt"
python3 -c "
import json, time
json.dump({'a': {'agent': 'codex', 'open': True, 'workspace': 5, 'address': 'aa',
                 'state': 'working', 'state_at': 1, 'about': 'boxes'},
           'b': {'agent': 'claude', 'open': True, 'workspace': 5, 'address': 'bb',
                 'state': 'idle', 'state_at': 1, 'announced_at': time.time()}},
          open('$S/state/sessions.json', 'w'))"
CLIENTS='[{"address":"0xaa","title":"","workspace":{"id":5}},{"address":"0xbb","title":"","workspace":{"id":5}}]' \
  fire Stop codex '{"session_id":"a"}'
check "says nothing: one dot dimmed and it has been said" "$(quiet)" "0"

echo "the session that does speak"
seed "$W"; fire Stop codex '{"session_id":"a"}'
check "leaves the mark that says so" \
  "$(python3 -c "import json;print('announced_at' in json.load(open('$S/state/sessions.json'))['a'])")" "True"

echo "a record whose fields are the wrong types entirely"
mkdir -p "$S/state"; : > "$S/fired.txt"
python3 -c "
import json
json.dump({'a': {'agent': 'codex', 'open': True, 'workspace': 5, 'address': 'aa',
                 'state': 'working', 'state_at': 1, 'about': 'boxes'},
           'b': {'address': ['not', 'a', 'string'], 'announced_at': 'soon', 'state': 'working'}},
          open('$S/state/sessions.json', 'w'))"
fire Stop codex '{"session_id":"a"}'
check "does not take the hook down" "$rc" "0"
check "and the state write still landed" "$(state a)" "idle"

echo "a stop from a session nobody has a record of"
seed '{}'; fire Stop codex '{"session_id":"ghost"}'
check "announces nothing" "$(cat "$S/fired.txt")" ""

echo "a tool finishing mid-turn"
seed "$W"; fire PostToolUse codex '{"session_id":"a"}'
check "is not a finish" "$(quiet)" "0"

echo "a subagent finishing while its parent works on"
seed "$W"; fire SubagentStop codex '{"session_id":"a"}'
check "is not a finish either" "$(quiet)" "0"

echo "a session ending, which is the other way a record turns idle"
seed "$W"; fire SessionEnd codex '{"session_id":"a"}'
check "is not announced: nobody waits on a session that is gone" "$(quiet)" "0"
check "and it is recorded idle all the same" "$(state a)" "idle"

rm -rf "$S"
echo; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
