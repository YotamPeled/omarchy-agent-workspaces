#!/usr/bin/env bash
# What the reporter does with a hook payload: the parts that decide what a slot is called.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; ((pass++)); else echo "  FAIL $1"; echo "       want: $3"; echo "       got:  $2"; ((fail++)); fi; }
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME
S="$(mktemp -d)"
rc=0
fire() {  # fire <event> <agent> <payload>; keeps the exit code, because a hook that dies
          # takes the state write with it
  printf '%s' "$3" | HOME="$S" AGENT_WS_NO_AI=1 python3 "$HERE/bin/agent-ws" hook "$1" --agent "$2" --state "$S/state" >"$S/err.txt" 2>&1
  rc=$?
}
field() { python3 -c "import json,sys;print((json.load(open(sys.argv[1])).get(sys.argv[2]) or {}).get(sys.argv[3],''))" "$S/state/sessions.json" "$1" "$2" 2>/dev/null; }
seed() { mkdir -p "$S/state"; python3 -c "
import json,sys,time
json.dump({sys.argv[1]: {'agent': sys.argv[2], 'open': True, 'workspace': 5, 'address': '0xaa',
                         'state': 'idle', 'state_at': 1.0, 'transcript': sys.argv[3]}},
          open(sys.argv[4], 'w'))" "$1" "$2" "${3:-}" "$S/state/sessions.json"; }

echo "an agent whose window title says only which folder it is in"
# A Codex transcript: the harness speaks first, then the user. Only the user names the work.
cat > "$S/rollout.jsonl" <<'JSON'
{"type":"session_meta","payload":{"session_id":"sid-codex","cwd":"/home/yotam"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/home/yotam</cwd>\n</environment_context>"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"take a look at the boxes project and see if we can get better results there"}]}}
JSON
seed sid-codex codex "$S/rollout.jsonl"
fire UserPromptSubmit codex '{"session_id":"sid-codex","turn_id":"t1","cwd":"/home/yotam"}'
check "is named from the first thing it was asked, read out of its own transcript" \
  "$(field sid-codex about)" "take a look at the boxes project and see if we can get better results there"
check "and is marked as working by the same event" "$(field sid-codex state)" "working"

echo "the same agent, on a later prompt"
fire UserPromptSubmit codex '{"session_id":"sid-codex","turn_id":"t2","cwd":"/home/yotam","prompt":"now do something else entirely"}'
check "keeps the name it already has, so the slot does not rename itself all evening" \
  "$(field sid-codex about)" "take a look at the boxes project and see if we can get better results there"

echo "a payload that carries the prompt outright"
seed sid-codex2 codex "$S/rollout.jsonl"
fire UserPromptSubmit codex '{"session_id":"sid-codex2","turn_id":"t1","prompt":"rename the odds column"}'
check "prefers it over reading the transcript" "$(field sid-codex2 about)" "rename the odds column"

echo "an agent that writes the work into its own window title"
seed sid-claude claude "$S/rollout.jsonl"
fire UserPromptSubmit claude '{"session_id":"sid-claude","turn_id":"t1","prompt":"rename the odds column"}'
check "keeps nothing: the bar reads its title for free" "$(field sid-claude about)" ""

echo "a transcript that says nothing usable"
: > "$S/empty.jsonl"
seed sid-codex3 codex "$S/empty.jsonl"
fire UserPromptSubmit codex '{"session_id":"sid-codex3","turn_id":"t1"}'
check "leaves the slot unnamed rather than inventing one" "$(field sid-codex3 about)" ""
check "and still marks it working" "$(field sid-codex3 state)" "working"

echo "a transcript record that is not shaped the way any agent writes one"
cat > "$S/odd.jsonl" <<'JSON'
{"payload":{"role":"user","content":[{"type":"input_text","text":null}]}}
{"payload":{"role":"user","content":[{"type":"input_text","text":"rename the odds column"}]}}
JSON
seed sid-odd codex "$S/odd.jsonl"
fire UserPromptSubmit codex '{"session_id":"sid-odd","turn_id":"t1"}'
check "does not take the state write down with it" "$rc" "0"
check "and the session is still marked working" "$(field sid-odd state)" "working"
check "and the next record that does read as a request is the one used" \
  "$(field sid-odd about)" "rename the odds column"

echo "a payload whose prompt key holds an object rather than a line of text"
seed sid-obj codex "$S/rollout.jsonl"
fire UserPromptSubmit codex '{"session_id":"sid-obj","turn_id":"t1","message":{"role":"user","content":[{"text":"hi"}]}}'
check "is ignored, so no slot is named after a dump of a data structure" \
  "$(field sid-obj about)" "take a look at the boxes project and see if we can get better results there"

echo "a multi-line prompt"
seed sid-multi codex ""
fire UserPromptSubmit codex '{"session_id":"sid-multi","turn_id":"t1","prompt":"first line\n\nsecond line"}'
check "is kept as one line" "$(field sid-multi about)" "first line second line"

echo "a prompt from a session nothing has ever recorded"
python3 -c "import json;json.dump({}, open('$S/state/sessions.json','w'))"
fire UserPromptSubmit codex '{"session_id":"ghost-1","turn_id":"t1","prompt":"fix the odds table"}'
check "creates no record, because an id we have never seen owns no window" \
  "$(python3 -c "import json;print(len(json.load(open('$S/state/sessions.json'))))")" "0"

rm -rf "$S"
echo
if ((fail)); then echo "$fail of $((pass+fail)) checks failed"; exit 1; fi
echo "all $pass checks passed"
