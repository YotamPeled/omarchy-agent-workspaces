#!/usr/bin/env bash
# What happens at the moment a workspace's dot dims: the sound and the toast, and every
# case that must stay silent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; ((pass++)); else echo "  FAIL $1"; echo "       want: $3"; echo "       got:  $2"; ((fail++)); fi; }
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME
S="$(mktemp -d)"
BIN="$S/bin"; QUIET="$S/quiet"; mkdir -p "$BIN" "$QUIET"

# Stubs. Each one records its argv; the toast and the player are what we are testing for,
# hyprctl is what tells the code which workspace you are looking at.
for f in omarchy-notification-send pw-play paplay canberra-gtk-play; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "$S/fired.txt"\n' "$f" \
    | sed "s|\$S|$S|" > "$BIN/$f"
  chmod +x "$BIN/$f"
done
cp "$BIN/omarchy-notification-send" "$QUIET/omarchy-notification-send"   # a machine with no player
cat > "$BIN/hyprctl" <<'HY'
#!/usr/bin/env bash
case "$*" in
  *activeworkspace*) echo "{\"id\": ${FOCUSED:-9}}" ;;
  *clients*) echo "[{\"address\": \"0xaa\", \"pid\": 1, \"title\": \"${WINTITLE:-}\", \"workspace\": {\"id\": 5}}]" ;;
  *) echo "{}" ;;
esac
HY
chmod +x "$BIN/hyprctl"; cp "$BIN/hyprctl" "$QUIET/hyprctl"

seed() {  # seed <json of sessions.json>
  mkdir -p "$S/state"; printf '%s' "$1" > "$S/state/sessions.json"; : > "$S/fired.txt"
}
fire() {  # fire <event> <agent> <payload>
  printf '%s' "$3" | PATH="${PATHDIR:-$BIN}:/usr/bin:/bin" HOME="$S" XDG_DATA_HOME="$S/share" \
    AGENT_WS_NO_AI=1 python3 "$HERE/bin/agent-ws" hook "$1" --agent "$2" --state "$S/state" \
    >"$S/err.txt" 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$S/fired.txt" ]] && break; sleep 0.1; done
  sleep 0.2   # anything else that was going to fire has had its turn by now
}
fired() { local n; n=$(grep -c "^$1" "$S/fired.txt" 2>/dev/null); echo "${n:-0}"; }
toast() { grep "^omarchy-notification-send" "$S/fired.txt" 2>/dev/null | head -1; }

WORKING='{"a":{"agent":"codex","open":true,"workspace":5,"address":"0xaa","state":"working","state_at":1,"about":"take a look at the boxes project"}}'

echo "a session that was working stops, on a workspace you are not looking at"
seed "$WORKING"
fire Stop codex '{"session_id":"a"}'
check "says so out loud"        "$(fired omarchy-notification-send)" "1"
check "and plays one sound"     "$(fired pw-play)" "1"
check "naming the workspace and what it was doing" "$(toast)" \
  "omarchy-notification-send --app-name Agent Workspaces -g 󰄬 Workspace 5 finished take a look at the boxes project"

echo "the same stop arriving again on a session already idle"
: > "$S/fired.txt"
fire Stop codex '{"session_id":"a"}'
check "stays quiet: the dot dimmed once" "$(fired omarchy-notification-send)" "0"

echo "a session stopping on the workspace you are already on"
seed "$WORKING"
FOCUSED=5 fire Stop codex '{"session_id":"a"}'
check "stays quiet: you watched it happen" "$(fired omarchy-notification-send)" "0"

echo "one of two sessions sharing a workspace stops"
seed '{"a":{"agent":"codex","open":true,"workspace":5,"address":"0xaa","state":"working","state_at":1},
       "b":{"agent":"claude","open":true,"workspace":5,"address":"0xbb","state":"working","state_at":1}}'
fire Stop codex '{"session_id":"a"}'
check "stays quiet: the slot is still lit by the other one" "$(fired omarchy-notification-send)" "0"

echo "an agent that keeps no opening request, because the bar reads its title"
seed '{"a":{"agent":"claude","open":true,"workspace":5,"address":"aa","state":"working","state_at":1}}'
WINTITLE='✳ wire the odds column' fire Stop claude '{"session_id":"a"}'
check "borrows the window title, without the mark it parks on" "$(toast)" \
  "omarchy-notification-send --app-name Agent Workspaces -g 󰄬 Workspace 5 finished wire the odds column"

echo "a named workspace"
mkdir -p "$S/.config/omarchy"
echo '{"5": "rss-digest"}' > "$S/.config/omarchy/workspace-names.json"
seed "$WORKING"
fire Stop codex '{"session_id":"a"}'
check "is announced by its name, not its number" "$(toast | grep -c 'rss-digest finished')" "1"
rm "$S/.config/omarchy/workspace-names.json"

echo "a machine with no audio player installed"
seed "$WORKING"
PATHDIR="$QUIET" fire Stop codex '{"session_id":"a"}'
check "still gets the toast" "$(fired omarchy-notification-send)" "1"

echo "your own sound, named in the config"
cp /dev/null "$S/mine.oga"
printf '{"finish_sound": "%s/mine.oga"}' "$S" > "$S/.config/omarchy/agent-workspaces.json"
seed "$WORKING"
fire Stop codex '{"session_id":"a"}'
check "is the one that plays" "$(grep -c "pw-play --volume 0.35 $S/mine.oga" "$S/fired.txt")" "1"

echo "both switched off"
echo '{"finish_sound": false, "finish_toast": false}' > "$S/.config/omarchy/agent-workspaces.json"
seed "$WORKING"
fire Stop codex '{"session_id":"a"}'
check "is silence, and no call to Hyprland to find out where you are" "$(cat "$S/fired.txt")" ""
check "and the session is still recorded as idle" \
  "$(python3 -c "import json;print(json.load(open('$S/state/sessions.json'))['a']['state'])")" "idle"
rm "$S/.config/omarchy/agent-workspaces.json"

echo "a config file that is not JSON"
echo 'not json' > "$S/.config/omarchy/agent-workspaces.json"
seed "$WORKING"
fire Stop codex '{"session_id":"a"}'
check "falls back to the defaults instead of taking the hook down" "$(fired omarchy-notification-send)" "1"
rm "$S/.config/omarchy/agent-workspaces.json"

echo "a stop from a session nobody has a record of"
seed '{}'
fire Stop codex '{"session_id":"ghost"}'
check "announces nothing" "$(cat "$S/fired.txt")" ""

echo "a tool finishing mid-turn"
seed "$WORKING"
fire PostToolUse codex '{"session_id":"a"}'
check "is not a finish" "$(fired omarchy-notification-send)" "0"

echo "a subagent finishing while its parent works on"
seed "$WORKING"
fire SubagentStop codex '{"session_id":"a"}'
check "is not a finish either" "$(fired omarchy-notification-send)" "0"

rm -rf "$S"
echo; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
