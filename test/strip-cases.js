// ---------- the cases ----------
let pass = 0, fail = 0;
function check(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { console.log("  ok   " + name); pass++; }
  else { console.log("  FAIL " + name + "\n       want: " + w + "\n       got:  " + g); fail++; }
}
const win = (title, addr, extra) => Object.assign({ title, address: addr, activated: false, urgent: false, lastIpcObject: {} }, extra || {});
const ws = (...tls) => ({ toplevels: { values: tls } });
const rec = (addr, agent, state, open) => ({ address: addr, agent, state, open: open !== false, workspace: 3 });
const only = s => s.map(x => [x.agent, x.state]);

root.sess = {}; root.needs = {};
check("a Claude window still works off its title alone, with no record at all",
  only(root.sessionsIn(ws(win("◐ fixing the bar", "aa")))), [["claude", "working"]]);
check("and its idle mark too", only(root.sessionsIn(ws(win("✳ fixing the bar", "aa")))), [["claude", "idle"]]);

check("a Codex window with no record and no mark is not a session",
  only(root.sessionsIn(ws(win("foot", "bb")))), []);
root.sess = { s1: rec("bb", "codex", "working") };
check("the same window, once Codex's hook has recorded it, is",
  only(root.sessionsIn(ws(win("foot", "bb")))), [["codex", "working"]]);
root.sess = { s1: rec("bb", "codex", "idle") };
check("and follows the recorded state when it stops",
  only(root.sessionsIn(ws(win("foot", "bb")))), [["codex", "idle"]]);
root.sess = { s1: rec("bb", "codex", "working", false) };
check("a closed session is not drawn",
  only(root.sessionsIn(ws(win("foot", "bb")))), []);

root.sess = { s1: rec("cc", "muse", "idle") };
check("Muse working shows from its own title mark, ahead of a record that lags",
  only(root.sessionsIn(ws(win("⠧ work", "cc")))), [["muse", "working"]]);
check("Muse idle has no title mark, so the record is what keeps its slot",
  only(root.sessionsIn(ws(win("work", "cc")))), [["muse", "idle"]]);

root.sess = { s1: rec("dd", "muse", "working") };
root.needs = { "0xdd": { at: 1, sid: "s1" } };
check("a raised hand wins over everything, and the address prefix does not matter",
  only(root.sessionsIn(ws(win("⠧ work", "dd")))), [["muse", "needs"]]);
root.needs = {};

root.sess = { s1: rec("ee", "codex", "working"), s2: rec("ff", "claude", "idle") };
const two = root.sessionsIn(ws(win("foot", "ee"), win("✳ hello", "ff", { activated: true })));
check("two agents in one workspace are both seen", only(two).length, 2);
check("the worst state is what the slot shows", root.worst(two), "working");
check("the focused one gives the slot its letter", root.agentMark(two), "C");
const two2 = root.sessionsIn(ws(win("foot", "ee", { activated: true }), win("✳ hello", "ff")));
check("focus moves the letter", root.agentMark(two2), "X");

root.sess = { s1: { address: "gg", open: true } };
check("a record written by an older version, with no agent and no state, still keeps its slot",
  only(root.sessionsIn(ws(win("foot", "gg")))), [["", "idle"]]);
check("and shows no letter rather than a wrong one",
  root.agentMark(root.sessionsIn(ws(win("foot", "gg")))), "");

root.sess = { s1: Object.assign(rec("mm", "codex", "working"), { about: "port the odds table to the new feed" }) };
check("a Codex slot is named after what it was asked, not the folder it was started in",
  root.sessionsIn(ws(win("\u280f yotam", "mm")))[0].title, "port the odds table to the new feed");
root.sess = { s1: rec("mm", "claude", "working") };
check("an agent that titles its own window still names the slot from that title",
  root.sessionsIn(ws(win("\u25d1 keyboard scrolling", "mm")))[0].title, "keyboard scrolling");

root.sess = {};
check("a braille mark with no record shows working, because Muse and Codex share that mark",
  only(root.sessionsIn(ws(win("\u2807 work", "jj")))), [["", "working"]]);
check("and shows no letter, because the mark cannot say which of the two it is",
  root.agentMark(root.sessionsIn(ws(win("\u2807 work", "jj")))), "");

check("an untitled window is not mistaken for a session",
  only(root.sessionsIn(ws(win("", "hh")))), []);
check("a window whose title merely starts with a letter is not one either",
  only(root.sessionsIn(ws(win("Cargo.toml — helix", "ii")))), []);

// what the review round caught
root.sess = { s1: { address: "jj", agent: "codex", state: "working", open: true, pid: 4242 } };
check("a record left open by a session that died does not claim the window that reused its address",
  only(root.sessionsIn(ws(win("someone else", "jj", { lastIpcObject: { pid: 9999 } })))), []);
check("and it does claim its own window",
  only(root.sessionsIn(ws(win("codex", "jj", { lastIpcObject: { pid: 4242 } })))), [["codex", "working"]]);
root.sess = { s1: { address: "jj", agent: "codex", state: "working", open: true } };
check("a record from an older version, which carries no process, is still trusted on the address",
  only(root.sessionsIn(ws(win("codex", "jj", { lastIpcObject: { pid: 9999 } })))), [["codex", "working"]]);

root.sess = {
  older: { address: "kk", agent: "codex", state: "idle", open: true, state_at: 100 },
  newer: { address: "kk", agent: "muse", state: "working", open: true, state_at: 200 },
};
check("two sessions in one window: the slot shows the one that moved most recently",
  only(root.sessionsIn(ws(win("shared", "kk")))), [["muse", "working"]]);

console.log(fail ? `\n${fail} failed, ${pass} passed` : `\nall ${pass} checks passed`);
process.exit(fail ? 1 : 0);
