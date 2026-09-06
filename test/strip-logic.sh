#!/usr/bin/env bash
# What a slot decides, driven with fake windows and fake records. The functions are lifted
# out of Workspaces.qml at run time, so this cannot drift from the widget it is testing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v node >/dev/null || { echo "SKIP: node is not installed"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/run.js" <<'JS'
const root = {
  workingGlyphs: "◐◑◒◓", idleGlyph: "✳", museGlyphs: "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏",
  agentMarks: { claude: "C", codex: "X", muse: "M" },
  sess: {}, needs: {}, lastActive: {},
  normAddr(a) { return String(a || "").replace(/^0x/i, "").toLowerCase() },
};
JS
python3 - "$HERE/Workspaces.qml" >> "$T/run.js" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
out = []
for n in ("recorded", "ownsWindow", "sessionsIn", "worst", "lead", "agentMark"):
    a = s.index(f"  function {n}(")
    nxt = len(s)
    for m in re.finditer(r"\n  (function |// |readonly |property |Timer|implicitWidth)", s[a+10:]):
        nxt = a + 10 + m.start(); break
    out.append(s[a:nxt].rstrip())
body = "\n".join(out)
print(re.sub(r"^  function (\w+)\(", r"root.\1 = function(", body, flags=re.M))
PY
cat "$HERE/test/strip-cases.js" >> "$T/run.js"
node "$T/run.js"
